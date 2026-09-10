/// The account roster bound, at the seam that enforces it.
///
/// `kMaxCirclesPerAccount` is what keeps a production burst from ever deferring
/// a circle — and with it, keeps `LOCATION_MESSAGE_RETENTION_SECS` covering
/// every roster the app admits (`publish_stagger_test.dart` holds that
/// arithmetic). This file holds the other half: that the two operations which
/// can grow the roster actually refuse, at the exact boundary, without touching
/// anything on the way out.
///
/// Driven through [NostrCircleService.withInjectedManager] against a fake
/// [CircleManagerFfi], so the refusal is exercised where it lives rather than
/// where a page happens to call it. The fake's roster-growing methods FAIL if
/// reached, which is how "refused" is distinguished from "attempted and then
/// failed": a bound that stages an MLS group first and rejects afterwards would
/// leave a half-created circle behind.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/publish_stagger.dart';

import '../mocks/mock_relay_service.dart';

/// A stored circle row as the core hands it back, at [status].
CircleWithMembersFfi _row(int index, String status) => CircleWithMembersFfi(
  circle: CircleFfi(
    mlsGroupId: Uint8List.fromList([index]),
    nostrGroupId: Uint8List.fromList(List<int>.filled(32, index)),
    displayName: 'Circle $index',
    circleType: 'location_sharing',
    relays: const ['wss://relay.example'],
    createdAt: 1700000000,
    updatedAt: 1700000000,
  ),
  membershipStatus: status,
  members: const [],
);

List<CircleWithMembersFfi> _rows(int count, {required String status}) => [
  for (var i = 0; i < count; i++) _row(i, status),
];

/// Thrown by the fake's `createCircle` so a test can tell "the gate let this
/// through" from "the gate refused it" without needing a constructible
/// `CircleCreationResultFfi` (its `pending` is an opaque Rust handle).
class _ReachedTheCore implements Exception {}

class _FakeManager implements CircleManagerFfi {
  _FakeManager({this.visible = const [], this.rosterReadThrows = false});

  /// What `getVisibleCircles` reports — the authoritative roster.
  List<CircleWithMembersFfi> visible;

  /// Makes the roster read fail, so the fail-closed direction is testable.
  bool rosterReadThrows;

  /// Holds the FIRST `acceptInvitation` open until completed, so a test can
  /// have one accept genuinely in flight rather than relying on where the
  /// microtask queue happens to interleave two.
  ///
  /// Only the first: a second ingest must be free to RETURN, so a gate that
  /// wrongly admits it fails the test on the value it produced instead of
  /// hanging until the suite's timeout.
  Completer<void>? acceptGate;

  int createCircleCalls = 0;
  int acceptInvitationCalls = 0;

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async {
    if (rosterReadThrows) throw Exception('roster unreadable');
    return visible;
  }

  @override
  Future<CircleCreationResultFfi> createCircle({
    required List<int> identitySecretBytes,
    required List<MemberKeyPackageFfi> members,
    required String name,
    required String circleType,
    required List<String> relays,
    required List<String> creatorFallbackRelays,
    String? description,
  }) async {
    createCircleCalls++;
    throw _ReachedTheCore();
  }

  @override
  Future<CircleWithMembersFfi> acceptInvitation({
    required List<int> giftWrapId,
  }) async {
    acceptInvitationCalls++;
    if (acceptInvitationCalls == 1) await acceptGate?.future;
    return _row(99, 'accepted');
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

NostrCircleService _service(_FakeManager manager, {MockRelayService? relay}) =>
    NostrCircleService.withInjectedManager(
      relayService: relay ?? MockRelayService(),
      injectedManager: manager,
    );

/// The fake core's own refusal to mint an opaque `PendingStateRefFfi`, as the
/// service reports it — anything BUT the roster refusal, which is how a test
/// asserts the gate let the call through.
final Matcher _reachesTheCore = throwsA(
  allOf(
    isA<CircleServiceException>(),
    isNot(isA<CircleRosterFullException>()),
  ),
);

Future<CircleCreationResult> _create(NostrCircleService service) =>
    service.createCircle(
      identitySecretBytes: List<int>.filled(32, 7),
      memberKeyPackages: const [],
      name: 'New Circle',
      circleType: CircleType.locationSharing,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('creating a circle', () {
    test('is admitted one circle below the bound', () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 1, status: 'accepted'),
      );

      await expectLater(_create(_service(manager)), _reachesTheCore);

      expect(
        manager.createCircleCalls,
        1,
        reason: 'a roster below the bound must reach the core; the throw is '
            'the fake refusing to mint an opaque handle, not the gate',
      );
    });

    test('is refused AT the bound, and nothing is staged', () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount, status: 'accepted'),
      );
      final relay = MockRelayService();

      await expectLater(
        _create(_service(manager, relay: relay)),
        throwsA(isA<CircleRosterFullException>()),
      );

      expect(
        manager.createCircleCalls,
        0,
        reason: 'refusing after staging would leave an MLS group and a '
            'gift-wrapped Welcome behind for a circle the user never got',
      );
      expect(
        relay.methodCalls,
        isEmpty,
        reason: 'a refusal must leave nothing on the wire. No Welcome CAN '
            'exist — it comes from the core result the assertion above proves '
            'was never asked for — so what this pins is the rest: a refused '
            'create opens no socket of its own, before the gate or after it',
      );
    });

    test('stays refused above the bound', () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount + 3, status: 'accepted'),
      );

      await expectLater(
        _create(_service(manager)),
        throwsA(isA<CircleRosterFullException>()),
      );
      expect(manager.createCircleCalls, 0);
    });

    test('counts only accepted memberships, never pending invitations',
        () async {
      // A pending invitation publishes nothing, so it occupies no burst slot —
      // counting it would refuse a create the coverage argument allows.
      final manager = _FakeManager(
        visible: [
          ..._rows(kMaxCirclesPerAccount + 5, status: 'pending'),
          ..._rows(1, status: 'accepted'),
        ],
      );

      await expectLater(_create(_service(manager)), _reachesTheCore);

      expect(manager.createCircleCalls, 1);
    });

    test('is refused when the roster cannot be read at all (fails closed)',
        () async {
      final manager = _FakeManager(rosterReadThrows: true);

      await expectLater(
        _create(_service(manager)),
        throwsA(isA<CircleServiceException>()),
      );

      expect(
        manager.createCircleCalls,
        0,
        reason: 'an unreadable roster is an unknown roster; growing it anyway '
            'would make the bound advisory',
      );
    });
  });

  group('accepting an invitation', () {
    test('is admitted one circle below the bound', () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 1, status: 'accepted'),
      );

      final circle = await _service(manager).acceptInvitation(const [1, 2, 3]);

      expect(circle.membershipStatus, MembershipStatus.accepted);
      expect(manager.acceptInvitationCalls, 1);
    });

    test('is refused AT the bound, and the held Welcome is not ingested',
        () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount, status: 'accepted'),
      );

      await expectLater(
        _service(manager).acceptInvitation(const [1, 2, 3]),
        throwsA(isA<CircleRosterFullException>()),
      );

      expect(
        manager.acceptInvitationCalls,
        0,
        reason: 'ingesting then refusing would consume the invitation, so the '
            'user could not accept it after leaving a circle',
      );
    });

    test('stays refused above the bound', () async {
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount + 3, status: 'accepted'),
      );

      await expectLater(
        _service(manager).acceptInvitation(const [1, 2, 3]),
        throwsA(isA<CircleRosterFullException>()),
      );
      expect(manager.acceptInvitationCalls, 0);
    });

    test('counts only accepted memberships, never pending invitations',
        () async {
      final manager = _FakeManager(
        visible: [
          ..._rows(kMaxCirclesPerAccount + 5, status: 'pending'),
          ..._rows(1, status: 'accepted'),
        ],
      );

      await _service(manager).acceptInvitation(const [1, 2, 3]);

      expect(manager.acceptInvitationCalls, 1);
    });

    test('is refused when the roster cannot be read at all (fails closed)',
        () async {
      final manager = _FakeManager(rosterReadThrows: true);

      await expectLater(
        _service(manager).acceptInvitation(const [1, 2, 3]),
        throwsA(isA<CircleServiceException>()),
      );
      expect(manager.acceptInvitationCalls, 0);
    });

    test('is admitted again once the user makes room', () async {
      // The remedy the copy promises: "leave a circle, then accept this
      // invitation". A refusal that consumed the invitation, or a gate that
      // stayed latched, would make that advice false.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount, status: 'accepted'),
      );
      final service = _service(manager);

      await expectLater(
        service.acceptInvitation(const [1, 2, 3]),
        throwsA(isA<CircleRosterFullException>()),
      );

      manager.visible = _rows(kMaxCirclesPerAccount - 1, status: 'accepted');

      final circle = await service.acceptInvitation(const [1, 2, 3]);

      expect(circle.membershipStatus, MembershipStatus.accepted);
      expect(
        manager.acceptInvitationCalls,
        1,
        reason: 'the held Welcome survived the refusal, so the same gift-wrap '
            'id ingests on the retry',
      );
    });
  });

  group('two growths in flight at once', () {
    test('admit exactly one when only one slot is left', () async {
      // Each invitation card owns its own spinner, so two Accept buttons stay
      // enabled together. Both read the roster before either writes a row, so
      // without an in-flight reservation both see nine and both proceed —
      // eleven circles, and the bound stops being a bound.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 1, status: 'accepted'),
      )..acceptGate = Completer<void>();
      final service = _service(manager);

      final first = service.acceptInvitation(const [1]);
      final second = service.acceptInvitation(const [2]);

      await expectLater(second, throwsA(isA<CircleRosterFullException>()));
      expect(
        manager.acceptInvitationCalls,
        1,
        reason: 'the second accept must not reach the core while the first '
            'still holds the last slot',
      );

      manager.acceptGate!.complete();
      expect((await first).membershipStatus, MembershipStatus.accepted);
    });

    test('release the slot so a later growth is admitted', () async {
      // The reservation is not a one-way latch: once the first accept settles
      // its slot is the roster's problem again, not the gate's.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 1, status: 'accepted'),
      );
      final service = _service(manager);

      await service.acceptInvitation(const [1]);
      await service.acceptInvitation(const [2]);

      expect(manager.acceptInvitationCalls, 2);
    });

    test('a refusal does not loosen the next check', () async {
      // A refusal reserves nothing, so it must release nothing. Moving the gate
      // inside either method's `try` looks tidier and is behaviourally
      // invisible on the FIRST refusal — but the `finally` would then give back
      // a slot the refusal never took, the count would go negative, and the
      // second attempt at the bound would be admitted.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount, status: 'accepted'),
      );
      final service = _service(manager);

      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          _create(service),
          throwsA(isA<CircleRosterFullException>()),
        );
        await expectLater(
          service.acceptInvitation(const [1]),
          throwsA(isA<CircleRosterFullException>()),
        );
      }

      expect(manager.createCircleCalls, 0);
      expect(manager.acceptInvitationCalls, 0);
    });

    test('release the slot even when the growth fails', () async {
      // A create that throws inside the core must not consume a slot forever;
      // a leaked reservation would refuse a create the roster allows.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 1, status: 'accepted'),
      );
      final service = _service(manager);

      await expectLater(_create(service), _reachesTheCore);
      await expectLater(_create(service), _reachesTheCore);

      expect(manager.createCircleCalls, 2);
    });

    test('a successful growth gives back exactly one slot', () async {
      // The release path's other direction, and the one that fails SILENTLY. A
      // reservation released twice on the success path — an extra
      // `_releaseRosterSlot()` before the return, a `finally` that also runs on
      // a nested try — drives the counter negative, so `held + reserved` sits
      // BELOW the roster's real size and the gate admits one extra circle for
      // every growth that already succeeded. Every other test here either
      // refuses from the start or succeeds and stops, so none of them ever asks
      // the gate a question after a success: this one does.
      final manager = _FakeManager(
        visible: _rows(kMaxCirclesPerAccount - 3, status: 'accepted'),
      );
      final service = _service(manager);

      for (var grown = 1; grown <= 3; grown++) {
        await service.acceptInvitation([grown]);
        // The core wrote a row, so the authoritative roster is one larger.
        manager.visible = _rows(
          kMaxCirclesPerAccount - 3 + grown,
          status: 'accepted',
        );
      }
      expect(manager.acceptInvitationCalls, 3);

      // The roster is now full. Both growth paths must refuse, which they can
      // only do if each of the three releases returned exactly one slot.
      await expectLater(
        service.acceptInvitation(const [9]),
        throwsA(isA<CircleRosterFullException>()),
      );
      await expectLater(
        _create(service),
        throwsA(isA<CircleRosterFullException>()),
      );
      expect(manager.acceptInvitationCalls, 3);
      expect(manager.createCircleCalls, 0);
    });
  });

  test('the refusal carries no internal detail a UI could leak', () {
    // Security Rule 8: the pages localize this refusal and never render the
    // exception, but the type is what they switch on, so it must stay safe to
    // log. A data-free message cannot carry an MLS group id or relay prose.
    const refusal = CircleRosterFullException();
    expect(refusal.message, isNot(contains(RegExp('[0-9a-f]{8}'))));
    expect(refusal.toString(), isNot(contains('wss://')));
  });
}
