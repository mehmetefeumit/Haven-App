/// Tests for [PendingLeaveService] — the REV-1 durable leaver-backstop intent.
///
/// Covers:
/// - marker set / cleared / survives a simulated crash (re-instantiation)
/// - the stored value is ONLY the public nostr_group_id hex (never the MLS
///   group id, a pubkey, or secret material)
/// - TEST 3: durable intent survives a restart — a leave marked mid-flow and
///   NOT cleared (crash) is finished by `resumePendingLeaves` on the next
///   launch (still-present circle → re-run leaveCircle → marker cleared)
/// - resume clears a stale marker for an already-gone circle without re-leaving
/// - resume keeps the marker when the re-run leave fails (retry next launch)
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/pending_leave_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mock_circle_service.dart';

/// Lowercase, 2-digit-per-byte hex — the encoding [PendingLeaveService] uses
/// for the public nostr_group_id marker. Duplicated here so the privacy
/// assertion is independent of the implementation.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Builds a [PendingLeaveService] over fake [SharedPreferences] seeded with
  /// [prefsValues].
  Future<({PendingLeaveService service, SharedPreferences prefs})> makeService({
    Map<String, Object> prefsValues = const {},
  }) async {
    SharedPreferences.setMockInitialValues(prefsValues);
    final prefs = await SharedPreferences.getInstance();
    return (service: PendingLeaveService(prefs: prefs), prefs: prefs);
  }

  // ---------------------------------------------------------------------------
  // Marker access
  // ---------------------------------------------------------------------------

  group('marker access', () {
    test('pendingLeaves is empty by default', () async {
      final (:service, prefs: _) = await makeService();
      expect(service.pendingLeaves, isEmpty);
    });

    test('markLeaving records the circle; clearLeaving removes it', () async {
      final (:service, prefs: _) = await makeService();
      const nostrGroupId = [5, 6, 7, 8];

      await service.markLeaving(nostrGroupId);
      expect(service.isLeaving(nostrGroupId), isTrue);
      expect(service.pendingLeaves, equals({_hex(nostrGroupId)}));

      await service.clearLeaving(nostrGroupId);
      expect(service.isLeaving(nostrGroupId), isFalse);
      expect(service.pendingLeaves, isEmpty);
    });

    test('marking is idempotent — one marker per circle', () async {
      final (:service, prefs: _) = await makeService();
      const nostrGroupId = [1, 2, 3, 4];
      await service.markLeaving(nostrGroupId);
      await service.markLeaving(nostrGroupId);
      expect(service.pendingLeaves, equals({_hex(nostrGroupId)}));
    });

    test('tracks independent markers for multiple circles', () async {
      final (:service, prefs: _) = await makeService();
      const a = [1, 1, 1, 1];
      const b = [2, 2, 2, 2];
      await service.markLeaving(a);
      await service.markLeaving(b);
      expect(service.pendingLeaves, equals({_hex(a), _hex(b)}));

      await service.clearLeaving(a);
      expect(
        service.pendingLeaves,
        equals({_hex(b)}),
        reason: 'clearing one circle leaves the others pending',
      );
    });

    test(
      'the stored value is ONLY the public nostr_group_id hex '
      '(no MLS id / pubkey / secret)',
      () async {
        final (:service, :prefs) = await makeService();
        const nostrGroupId = [0xAB, 0xCD, 0xEF, 0x01];
        await service.markLeaving(nostrGroupId);

        // Exactly one key is written, holding the hex of the PUBLIC group id.
        final keys = prefs.getKeys();
        expect(keys, equals({kPendingLeaveKey}));
        expect(
          prefs.getStringList(kPendingLeaveKey),
          equals([_hex(nostrGroupId)]),
          reason: 'stores the relay-visible nostr_group_id, never the MLS id',
        );
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Crash survival (mirrors the pending-MLS-wipe durability contract)
  // ---------------------------------------------------------------------------

  group('durability', () {
    test('a marker survives re-instantiation (a simulated crash)', () async {
      final (:service, :prefs) = await makeService();
      const nostrGroupId = [9, 9, 9, 9];

      await service.markLeaving(nostrGroupId);
      // No clearLeaving() — simulate a crash mid-backstop.

      final revived = PendingLeaveService(prefs: prefs);
      expect(
        revived.isLeaving(nostrGroupId),
        isTrue,
        reason: 'a leave marked but not cleared must be visible next launch',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // TEST 3 — durable intent survives a restart and is FINISHED by resume.
  // ---------------------------------------------------------------------------

  group('resumePendingLeaves (TEST 3 — durable intent survives restart)', () {
    test(
      'crash mid-leave → next-launch resume re-runs leaveCircle and clears '
      'the marker',
      () async {
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: const [10, 20, 30, 40],
          nostrGroupId: const [50, 60, 70, 80],
        );
        final mock = MockCircleService(circles: [circle]);

        // Phase 1: a leave is marked but the process "crashes" before clearing.
        final (:service, :prefs) = await makeService();
        await service.markLeaving(circle.nostrGroupId);

        // Phase 2: a FRESH launch reads the durable marker and finishes.
        final revived = PendingLeaveService(prefs: prefs);
        expect(
          revived.isLeaving(circle.nostrGroupId),
          isTrue,
          reason: 'precondition: the interrupted leave is still pending',
        );

        await revived.resumePendingLeaves(
          circleService: mock,
          selfPubkeyHex: 'a' * 64,
        );

        // The resume re-entered the leave for exactly this circle — no separate
        // membership probe (leaveCircle -> planLeave resolves both cases)...
        expect(
          mock.leaveCircleCalledWith,
          hasLength(1),
          reason: 'the pending circle is re-left exactly once',
        );
        expect(mock.leaveCircleCalledWith.single.mlsGroupId, circle.mlsGroupId);
        expect(
          mock.methodCalls,
          isNot(contains('stillAMember')),
          reason: 'resume no longer runs a redundant membership probe — '
              'leaveCircle handles still-member vs already-removed itself',
        );
        // ...and, having finished, cleared the durable marker.
        expect(
          revived.isLeaving(circle.nostrGroupId),
          isFalse,
          reason: 'the marker is cleared once the resumed leave completes',
        );
      },
    );

    test(
      'a marker for an already-gone circle is cleared without re-leaving',
      () async {
        // The circle is NOT in the visible set → its leave already completed
        // (and wiped) before the crash — the resume just clears the marker.
        final mock = MockCircleService(circles: const []);
        final (:service, :prefs) = await makeService();
        const goneNostrGroupId = [7, 7, 7, 7];
        await service.markLeaving(goneNostrGroupId);

        final revived = PendingLeaveService(prefs: prefs);
        await revived.resumePendingLeaves(
          circleService: mock,
          selfPubkeyHex: 'b' * 64,
        );

        expect(
          mock.methodCalls,
          isNot(contains('leaveCircle')),
          reason: 'an already-gone circle is not re-left',
        );
        expect(
          revived.isLeaving(goneNostrGroupId),
          isFalse,
          reason: 'the stale marker is cleared',
        );
      },
    );

    test('a failed resume keeps the marker set for the next launch', () async {
      final circle = TestCircleFactory.createCircle(
        mlsGroupId: const [11, 22, 33, 44],
        nostrGroupId: const [55, 66, 77, 88],
      );
      final mock = MockCircleService(circles: [circle])
        ..shouldThrowOnLeaveCircle = true; // the resumed leave still fails

      final (:service, :prefs) = await makeService();
      await service.markLeaving(circle.nostrGroupId);

      final revived = PendingLeaveService(prefs: prefs);
      await revived.resumePendingLeaves(
        circleService: mock,
        selfPubkeyHex: 'c' * 64,
      );

      expect(mock.methodCalls, contains('leaveCircle'));
      expect(
        revived.isLeaving(circle.nostrGroupId),
        isTrue,
        reason: 'a leave that still fails keeps the marker for a later retry',
      );
    });

    test('resume is a no-op when nothing is pending', () async {
      final mock = MockCircleService(circles: const []);
      final (:service, prefs: _) = await makeService();

      await service.resumePendingLeaves(
        circleService: mock,
        selfPubkeyHex: 'd' * 64,
      );

      expect(
        mock.methodCalls,
        isEmpty,
        reason: 'no markers → the resume never touches the circle service',
      );
    });
  });
}
