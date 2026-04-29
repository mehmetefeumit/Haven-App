/// Regression guards for the ghost-admin IgnoredProposal path.
///
/// When MDK returns an `IgnoredProposal` for an event (e.g., an admin's
/// SelfRemove dropped by MDK's admin-gate), the service MUST:
///
///   1. Thread [DecryptResult.ignoredReason] into
///      [LocationFetchResult.pendingDepartureReason] so the UI can render
///      the "Leaving…" banner and unlock the admin Remove-member affordance.
///
///   2. NOT add the event id to [_seenEventIds]: the same event must be
///      re-examined on every fetch/poll cycle until an admin publishes a
///      RemoveMember commit that evicts the leaver.
///
///   3. Honour rule (2) inside [LocationSharingService.pollEvolutionEvents]
///      / [_runEvolutionPoll] as well — the evolution poller uses its own
///      seen-set add path and the early-continue must fire there too.
///
/// These tests exist as a separate file (rather than appended to the main
/// location_sharing_service_test.dart) because that file exceeds the Write
/// tool's read-back budget. They cover priority items 1–3 from the
/// ghost-admin audit.
///
/// See also: `docs/ADMIN_LEAVE_GHOST_BUG.md`
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Shared test circle — accepted membership, one member.
  final ignoredCircle = TestCircleFactory.createCircle(
    displayName: 'IgnoredCircle',
    membershipStatus: MembershipStatus.accepted,
    members: [
      TestCircleFactory.createMember(pubkey: 'sender1', displayName: 'Ada'),
    ],
  );

  // -------------------------------------------------------------------------
  // Priority 1: fetchMemberLocations surfaces ignoredReason
  // -------------------------------------------------------------------------

  group(
    'LocationSharingService.fetchMemberLocations — IgnoredProposal: '
    'pendingDepartureReason',
    () {
      test(
        'ignored result threads ignoredReason into '
        'LocationFetchResult.pendingDepartureReason',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"ignored-evt","kind":445,"content":"selfremove"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(ignoredReason: 'admin SelfRemove rejected'),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: ignoredCircle);

          expect(
            result.pendingDepartureReason,
            'admin SelfRemove rejected',
            reason:
                'ignoredReason must be surfaced as pendingDepartureReason '
                'so the UI can render the Leaving banner and unlock the '
                'admin Remove-member affordance',
          );
        },
      );

      test(
        'non-ignored result leaves pendingDepartureReason null',
        () async {
          // Guard against a regression that always sets the pending signal.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"commit-evt","kind":445,"content":"commit"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(groupUpdated: true),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: ignoredCircle);

          expect(
            result.pendingDepartureReason,
            isNull,
            reason:
                'A normal group-update must NOT set pendingDepartureReason',
          );
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  // Priority 2: fetchMemberLocations does NOT add ignored event to seen-set
  // -------------------------------------------------------------------------

  group(
    'LocationSharingService.fetchMemberLocations — IgnoredProposal: '
    'seen-set exclusion',
    () {
      test(
        'ignored result does NOT add the event id to _seenEventIds',
        () async {
          // The ignored event must remain eligible for re-examination on
          // every fetch until an admin publishes a RemoveMember commit.
          // If it were marked seen the pending-departure signal would
          // silently disappear on the next polling cycle — that is the
          // ghost-admin regression this test guards against.
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"ignored-evt2","kind":445,"content":"selfremove"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(ignoredReason: 'MDK admin gate'),
              // Provide a second result so the mock can answer the second
              // fetch's decrypt call.
              const DecryptResult(ignoredReason: 'MDK admin gate'),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          // First fetch — the event must not enter the seen set.
          await svc.fetchMemberLocations(circle: ignoredCircle);
          expect(
            svc.debugSeenEventIdsCount,
            0,
            reason:
                'ignored event must NOT be added to _seenEventIds; the next '
                'fetch must be able to re-examine it',
          );

          // Second fetch on the same event — decrypt must be invoked again
          // (i.e., the event was NOT blocked by the seen-set pre-check gate).
          await svc.fetchMemberLocations(circle: ignoredCircle);
          final decryptCalls = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(
            decryptCalls,
            2,
            reason:
                'same ignored event must be re-decrypted on each fetch — '
                'confirmed by seeing two total decryptLocation calls, one '
                'per fetch cycle',
          );
          // Still nothing in the seen set after two fetches.
          expect(svc.debugSeenEventIdsCount, 0);
        },
      );

      test(
        'a normally-processed event IS added to _seenEventIds (control)',
        () async {
          // Sanity / contrast: a successful non-ignored result marks the
          // event seen so the dedup gate short-circuits on the next fetch.
          // This ensures the ignored guard does not accidentally suppress
          // marking for all events.
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"normal-evt","kind":445,"content":"commit"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(groupUpdated: true),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: ignoredCircle);
          expect(
            svc.debugSeenEventIdsCount,
            1,
            reason:
                'a successfully-processed event MUST be added to '
                '_seenEventIds so subsequent fetches skip it',
          );
        },
      );
    },
  );

  // -------------------------------------------------------------------------
  // Priority 3: _runEvolutionPoll (via pollEvolutionEvents) seen-set exclusion
  // -------------------------------------------------------------------------

  group(
    'LocationSharingService.pollEvolutionEvents — IgnoredProposal: '
    'seen-set exclusion (regression guard for flutter-review bug A)',
    () {
      // Uses a distinct circle to keep the evolution-poll cursor isolated.
      final pollCircle = TestCircleFactory.createCircle(
        mlsGroupId: const [0xDE, 0xAD, 0xBE, 0xEF],
        nostrGroupId: const [0xCA, 0xFE, 0xBA, 0xBE],
        displayName: 'PollIgnored',
        membershipStatus: MembershipStatus.accepted,
        members: [
          TestCircleFactory.createMember(
            pubkey: 'pollsender',
            displayName: 'Eve',
          ),
        ],
      );

      test(
        '_runEvolutionPoll does NOT mark an ignored event as seen',
        () async {
          // An earlier draft of _runEvolutionPoll lacked the isIgnored
          // early-continue and would fall through to _seenEventIds.add.
          // This test locks in the must-not-mark-seen invariant for the
          // poll path, mirroring the fetchMemberLocations guard above.
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"poll-ignored","kind":445,"content":"selfremove"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(ignoredReason: 'admin gate poll'),
              // Second result for the second poll invocation.
              const DecryptResult(ignoredReason: 'admin gate poll'),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          // First poll — nothing must be added to the seen set.
          await svc.pollEvolutionEvents(circles: [pollCircle]);
          expect(
            svc.debugSeenEventIdsCount,
            0,
            reason:
                '_runEvolutionPoll must not mark an ignored event as seen; '
                'it must be re-examined on the next poll cycle',
          );

          // Second poll — same event must trigger another decrypt call
          // (not silently skipped by the seen-set gate).
          await svc.pollEvolutionEvents(circles: [pollCircle]);
          final decryptCalls = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(
            decryptCalls,
            2,
            reason:
                'ignored event must be re-presented to MDK on every poll '
                'until a RemoveMember commit resolves the ghost-admin state',
          );
          expect(svc.debugSeenEventIdsCount, 0);
        },
      );
    },
  );
}
