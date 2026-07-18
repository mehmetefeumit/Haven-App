/// Tests for [evolutionPollerProvider] and
/// [LocationSharingService.pollEvolutionEvents].
///
/// Verifies that:
/// - pollEvolutionEvents fetches kind-445 events for each accepted circle
/// - pollEvolutionEvents skips events already present in the seen-event set
/// - pollEvolutionEvents does not run concurrent polls
/// - evolutionPollerProvider invalidates circlesProvider on group state change
/// - evolutionPollerProvider returns false when no circles are present
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';

import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a single-result decrypt outcome mirroring the pre-Dark-Matter
/// `DecryptResult` shape this file's tests were written against.
List<LocationEventResult> _fakeDecrypt({
  DecryptedLocation? location,
  bool groupUpdated = false,
}) {
  final kind = groupUpdated
      ? LocationEventKind.groupUpdate
      : LocationEventKind.location;
  return [
    LocationEventResult(
      kind: kind,
      location: kind == LocationEventKind.location ? location : null,
      mlsGroupId: const [],
      epoch: 0,
    ),
  ];
}

/// Builds an accepted [Circle] for use in tests.
Circle _makeCircle({
  List<int>? nostrGroupId,
  List<int>? mlsGroupId,
  MembershipStatus status = MembershipStatus.accepted,
}) {
  return Circle(
    mlsGroupId: mlsGroupId ?? [1, 2, 3, 4],
    nostrGroupId: nostrGroupId ?? [5, 6, 7, 8],
    displayName: 'Test Circle',
    circleType: CircleType.locationSharing,
    relays: const ['wss://relay.example.com'],
    membershipStatus: status,
    members: const [],
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
  );
}

/// A [MockRelayService] whose [fetchGroupMessages] can be blocked by a
/// [Completer] so tests can assert on concurrency behaviour.
class _BlockingRelayService extends MockRelayService {
  _BlockingRelayService({required this.gate});

  final Completer<void> gate;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    await gate.future;
    return super.fetchGroupMessages(
      nostrGroupId: nostrGroupId,
      relays: relays,
      since: since,
      limit: limit,
    );
  }
}

// ---------------------------------------------------------------------------
// LocationSharingService.pollEvolutionEvents unit tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // -----------------------------------------------------------------------
  // Service-level tests (pollEvolutionEvents)
  // -----------------------------------------------------------------------

  group('LocationSharingService.pollEvolutionEvents', () {
    late MockCircleService mockCircleService;
    late MockRelayService mockRelayService;
    late LocationSharingService service;

    setUp(() {
      mockCircleService = MockCircleService();
      mockRelayService = MockRelayService();
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: mockRelayService,
      );
    });

    test('returns false immediately when circles list is empty', () async {
      final result = await service.pollEvolutionEvents(circles: []);

      expect(result, isFalse);
      expect(
        mockRelayService.methodCalls,
        isEmpty,
        reason: 'should not fetch from relays when there are no circles',
      );
    });

    test('skips pending circles, polls only accepted ones', () async {
      final accepted = _makeCircle(nostrGroupId: [1, 2, 3, 4]);
      final pending = _makeCircle(
        nostrGroupId: [5, 6, 7, 8],
        status: MembershipStatus.pending,
      );

      final result = await service.pollEvolutionEvents(
        circles: [accepted, pending],
      );

      // MockRelayService returns empty list → no group update.
      expect(result, isFalse);
      expect(
        mockRelayService.methodCalls
            .where((c) => c == 'fetchGroupMessages')
            .length,
        1,
        reason: 'should fetch only for the accepted circle',
      );
    });

    test('fetches kind-445 events for each accepted circle', () async {
      final circle1 = _makeCircle(nostrGroupId: [1, 2, 3, 4]);
      final circle2 = _makeCircle(nostrGroupId: [5, 6, 7, 8]);

      await service.pollEvolutionEvents(circles: [circle1, circle2]);

      expect(
        mockRelayService.methodCalls
            .where((c) => c == 'fetchGroupMessages')
            .length,
        2,
        reason: 'should fetch once per accepted circle',
      );
    });

    test('routes events through decryptLocation', () async {
      final relay = MockRelayService(
        groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
      );
      mockCircleService.decryptLocationResults = [
        _fakeDecrypt(groupUpdated: true),
      ];
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: relay,
      );

      final result = await service.pollEvolutionEvents(
        circles: [_makeCircle()],
      );

      expect(result, isTrue);
      expect(mockCircleService.methodCalls, contains('decryptLocation'));
    });

    test('skips events already present in the seen-event set', () async {
      // Warm up the seen-event set by processing an event through
      // fetchMemberLocations first, then verify pollEvolutionEvents
      // skips the same event ID.
      final relay = MockRelayService(
        groupMessages: const ['{"id":"evo1","kind":445,"content":"loc"}'],
      );
      mockCircleService.decryptLocationResults = [
        _fakeDecrypt(
          location: DecryptedLocation(
            senderPubkey: 'peer1',
            latitude: 1,
            longitude: 2,
            geohash: 'u',
            timestamp: DateTime.now(),
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        ),
      ];
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: relay,
      );
      final circle = _makeCircle();
      // First pass: location fetch marks evo1 as seen.
      await service.fetchMemberLocations(circle: circle);
      final callCountAfterFirst = mockCircleService.methodCalls
          .where((c) => c == 'decryptLocation')
          .length;
      expect(
        callCountAfterFirst,
        1,
        reason: 'first fetch should call decryptLocation once',
      );

      // Reset results so decryptLocation would return a new result if called.
      mockCircleService.decryptLocationResults = [
        _fakeDecrypt(groupUpdated: true),
      ];

      // Second pass via evolution poller: same event ID → should be skipped.
      await service.pollEvolutionEvents(circles: [circle]);

      final callCountAfterPoll = mockCircleService.methodCalls
          .where((c) => c == 'decryptLocation')
          .length;
      expect(
        callCountAfterPoll,
        1,
        reason: 'evolution poller should skip the already-seen event',
      );
    });

    test('does not run concurrent polls', () async {
      // Block the first poll at the relay fetch step.
      final gate = Completer<void>();
      final blockingRelay = _BlockingRelayService(gate: gate);
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: blockingRelay,
      );

      final circle = _makeCircle();

      // Start first poll without awaiting.
      final firstPoll = service.pollEvolutionEvents(circles: [circle]);

      // Second call while first is in-flight should return false immediately.
      final secondResult = await service.pollEvolutionEvents(circles: [circle]);
      expect(
        secondResult,
        isFalse,
        reason: 'second poll should skip when first is in progress',
      );

      // Unblock and complete the first poll.
      gate.complete();
      await firstPoll;
    });

    test('returns true when any group update is processed', () async {
      final relay = MockRelayService(
        groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
      );
      mockCircleService.decryptLocationResults = [
        _fakeDecrypt(groupUpdated: true),
      ];
      service = LocationSharingService(
        circleService: mockCircleService,
        relayService: relay,
      );

      final result = await service.pollEvolutionEvents(
        circles: [_makeCircle()],
      );

      expect(result, isTrue);
    });

    test(
      'returns true when only a peer location was processed (no group update)',
      () async {
        // Regression guard for the EvolutionPoller-vs-fetchMemberLocations
        // race: when the poller decrypts a peer location it MUST persist it
        // to `_locationCache` AND signal "anything changed" via the
        // returned bool, so the `evolutionPollerProvider` invalidates
        // `memberLocationsProvider` and the UI re-reads. Returning false
        // here would mean the location is silently dropped — the exact
        // failure mode the consolidated CI test surfaced.
        final relay = MockRelayService(
          groupMessages: const ['{"id":"evo1","kind":445,"content":"loc"}'],
        );
        mockCircleService.decryptLocationResults = [
          _fakeDecrypt(
            location: DecryptedLocation(
              senderPubkey: 'peer1',
              latitude: 1,
              longitude: 2,
              geohash: 'u',
              timestamp: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 1)),
            ),
          ),
        ];
        service = LocationSharingService(
          circleService: mockCircleService,
          relayService: relay,
        );

        final result = await service.pollEvolutionEvents(
          circles: [_makeCircle()],
        );

        // groupUpdated=false in DecryptResult, but a location WAS
        // persisted — the new contract returns true to drive
        // `memberLocationsProvider` invalidation downstream.
        expect(result, isTrue);
      },
    );

    // NOTE: "invokes publish+finalize for auto-commit evolution events" and
    // "calls clearPendingCommit when evolution event publish fails" were
    // removed (Dark Matter DM-4b). Both tested the pre-migration
    // receiver-side auto-commit dance: `decryptLocation` no longer returns
    // an outbound evolution event for a peer `SelfRemove` — the engine
    // publishes and applies that commit internally — and
    // `CircleService.publishEvolutionEvent` / `finalizePendingCommit` /
    // `clearPendingCommit` no longer exist. There is no surviving subject
    // for either test.
    test(
      'onAppPaused resets evolution cursor so resume re-fetches fully',
      () async {
        final trackingRelay = MockRelayService();
        service = LocationSharingService(
          circleService: mockCircleService,
          relayService: trackingRelay,
        );
        final circle = _makeCircle();

        // First poll records a cursor.
        await service.pollEvolutionEvents(circles: [circle]);
        // Pause clears the cursor.
        service.onAppPaused();
        // Second poll after pause must fetch without a `since` filter —
        // the relay mock records all fetchGroupMessages calls.
        await service.pollEvolutionEvents(circles: [circle]);

        expect(
          trackingRelay.methodCalls
              .where((c) => c == 'fetchGroupMessages')
              .length,
          2,
          reason: 'should fetch on both pre-pause and post-pause calls',
        );
      },
    );

    test(
      'handles relay fetch failure gracefully (continues to next circle)',
      () async {
        // First circle: relay throws. Second circle: succeeds.
        var callCount = 0;
        final failOnFirstRelay = _FailFirstRelayService(
          onFirstCall: () {
            callCount++;
            if (callCount == 1) {
              throw const RelayServiceException('Network error');
            }
          },
          groupMessages: const ['{"id":"evo2","kind":445,"content":"commit"}'],
        );
        mockCircleService.decryptLocationResults = [
          _fakeDecrypt(groupUpdated: true),
        ];
        service = LocationSharingService(
          circleService: mockCircleService,
          relayService: failOnFirstRelay,
        );

        final circle1 = _makeCircle(nostrGroupId: [1, 2]);
        final circle2 = _makeCircle(nostrGroupId: [3, 4]);

        // Should not throw even though the first relay call fails.
        final result = await service.pollEvolutionEvents(
          circles: [circle1, circle2],
        );

        expect(
          result,
          isTrue,
          reason: 'group update from second circle should still be reported',
        );
      },
    );
  });

  // -----------------------------------------------------------------------
  // Provider-level tests (evolutionPollerProvider)
  // -----------------------------------------------------------------------

  group('evolutionPollerProvider', () {
    test('returns false when no circles exist', () async {
      final mockCircle = MockCircleService(); // returns [] by default
      final mockRelay = MockRelayService();
      final locationService = LocationSharingService(
        circleService: mockCircle,
        relayService: mockRelay,
      );

      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockCircle),
          locationSharingServiceProvider.overrideWithValue(locationService),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(evolutionPollerProvider.future);
      expect(result, isFalse);
    });

    test('returns false when all circles are pending', () async {
      final pending = _makeCircle(status: MembershipStatus.pending);
      final mockCircle = MockCircleService(circles: [pending]);
      final mockRelay = MockRelayService();
      final locationService = LocationSharingService(
        circleService: mockCircle,
        relayService: mockRelay,
      );

      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockCircle),
          locationSharingServiceProvider.overrideWithValue(locationService),
        ],
      );
      addTearDown(container.dispose);

      final result = await container.read(evolutionPollerProvider.future);
      expect(result, isFalse);
      expect(mockRelay.methodCalls, isEmpty);
    });

    test('calls decryptLocation for fetched events', () async {
      final accepted = _makeCircle();
      final mockCircle = MockCircleService(circles: [accepted]);
      final mockRelay = MockRelayService(
        groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
      );
      mockCircle.decryptLocationResults = [_fakeDecrypt()];
      final locationService = LocationSharingService(
        circleService: mockCircle,
        relayService: mockRelay,
      );

      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockCircle),
          locationSharingServiceProvider.overrideWithValue(locationService),
        ],
      );
      addTearDown(container.dispose);

      await container.read(evolutionPollerProvider.future);

      expect(mockCircle.methodCalls, contains('decryptLocation'));
    });

    test('invalidates circlesProvider when group state changes', () async {
      final accepted = _makeCircle();
      final mockCircle = MockCircleService(circles: [accepted]);
      final mockRelay = MockRelayService(
        groupMessages: const ['{"id":"evo1","kind":445,"content":"commit"}'],
      );
      mockCircle.decryptLocationResults = [
        _fakeDecrypt(groupUpdated: true),
      ];
      final locationService = LocationSharingService(
        circleService: mockCircle,
        relayService: mockRelay,
      );

      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockCircle),
          locationSharingServiceProvider.overrideWithValue(locationService),
        ],
      );
      addTearDown(container.dispose);

      // Pre-load circlesProvider so we can observe invalidation.
      await container.read(circlesProvider.future);
      final circlesCallsBefore = mockCircle.methodCalls
          .where((c) => c == 'getVisibleCircles')
          .length;

      // Run the poller.
      final result = await container.read(evolutionPollerProvider.future);

      expect(result, isTrue);
      // Reading circlesProvider again after invalidation should trigger
      // a new getVisibleCircles call.
      await container.read(circlesProvider.future);
      final circlesCallsAfter = mockCircle.methodCalls
          .where((c) => c == 'getVisibleCircles')
          .length;
      expect(
        circlesCallsAfter,
        greaterThan(circlesCallsBefore),
        reason: 'circlesProvider should be invalidated after a group update',
      );
    });

    test(
      'does not invalidate circlesProvider when no group state change',
      () async {
        final accepted = _makeCircle();
        final mockCircle = MockCircleService(circles: [accepted]);
        final locationService = LocationSharingService(
          circleService: mockCircle,
          relayService: MockRelayService(),
        );

        final container = ProviderContainer(
          overrides: [
            circleServiceProvider.overrideWithValue(mockCircle),
            locationSharingServiceProvider.overrideWithValue(locationService),
          ],
        );
        addTearDown(container.dispose);

        await container.read(circlesProvider.future);
        final circlesCallsBefore = mockCircle.methodCalls
            .where((c) => c == 'getVisibleCircles')
            .length;

        await container.read(evolutionPollerProvider.future);

        // circlesProvider should NOT have been invalidated.
        final circlesCallsAfter = mockCircle.methodCalls
            .where((c) => c == 'getVisibleCircles')
            .length;
        // evolutionPollerProvider itself calls getVisibleCircles once;
        // circlesProvider should not have added a second call.
        expect(
          circlesCallsAfter,
          lessThanOrEqualTo(circlesCallsBefore + 1),
          reason:
              'circlesProvider should not be invalidated when no group update occurred',
        );
      },
    );

    test('handles getVisibleCircles failure gracefully', () async {
      final mockCircle = MockCircleService(shouldThrowOnGetCircles: true);
      final mockRelay = MockRelayService();
      final locationService = LocationSharingService(
        circleService: mockCircle,
        relayService: mockRelay,
      );

      final container = ProviderContainer(
        overrides: [
          circleServiceProvider.overrideWithValue(mockCircle),
          locationSharingServiceProvider.overrideWithValue(locationService),
        ],
      );
      addTearDown(container.dispose);

      // Should not throw.
      final result = await container.read(evolutionPollerProvider.future);
      expect(result, isFalse);
    });

    // NOTE: "integration: decrypt–publish–finalize sequence is invoked" was
    // removed (Dark Matter DM-4b) — its unique subject (asserting the
    // receiver-side auto-commit publish+finalize calls) no longer exists;
    // see the removal note in the `pollEvolutionEvents` group above. The
    // surviving behaviour it also exercised — a `groupUpdate` result
    // driving `evolutionPollerProvider`'s `true` return and
    // `circlesProvider` invalidation — is already covered by
    // "invalidates circlesProvider when group state changes" above.
  });
}

// ---------------------------------------------------------------------------
// Additional relay service stubs
// ---------------------------------------------------------------------------

/// A relay service that throws on the first [fetchGroupMessages] call,
/// then returns [groupMessages] on subsequent calls.
class _FailFirstRelayService extends MockRelayService {
  _FailFirstRelayService({required this.onFirstCall, super.groupMessages});

  final void Function() onFirstCall;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    onFirstCall();
    return super.fetchGroupMessages(
      nostrGroupId: nostrGroupId,
      relays: relays,
      since: since,
      limit: limit,
    );
  }
}
