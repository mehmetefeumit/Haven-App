/// Tests for LocationSharingService and related data classes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/utils/log_alias.dart';
import '../helpers/log_capture.dart';
import '../mocks/circle_service_retention_stubs.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

/// Builds a single-result `List<LocationEventResult>` mirroring the
/// pre-Dark-Matter `DecryptResult` shape this file's tests were written
/// against, so each fixture only needs to describe the outcome rather than
/// construct the folded-engine-result wrapper by hand.
///
/// `groupUpdated: true` maps to a single [LocationEventKind.groupUpdate]
/// result; otherwise a non-null [location] produces
/// [LocationEventKind.location], and omitting both produces a single
/// decrypted-but-non-location result ([LocationEventKind.location] with a
/// `null` location — e.g. the legacy avatar-wire case, or the Dark Matter
/// `joined` case when [kind] is overridden).
List<LocationEventResult> fakeDecrypt({
  DecryptedLocation? location,
  bool groupUpdated = false,
  // `[1, 2, 3, 4]` is `TestCircleFactory.createCircle()`'s own default
  // `mlsGroupId` — the ambient circle nearly every caller in this file
  // resolves against; `mlsGroupId` is never empty in production (Rust's
  // `convert_location_result` sets it on every variant).
  List<int> mlsGroupId = const [1, 2, 3, 4],
  LocationEventKind? kind,
}) {
  final resolvedKind =
      kind ??
      (groupUpdated
          ? LocationEventKind.groupUpdate
          : LocationEventKind.location);
  return [
    LocationEventResult(
      kind: resolvedKind,
      location: resolvedKind == LocationEventKind.location ? location : null,
      mlsGroupId: mlsGroupId,
      epoch: 0,
    ),
  ];
}

/// An empty decrypt result — the Dark Matter equivalent of "unprocessable" /
/// "already seen" (no folded results this ingest).
const List<LocationEventResult> noDecryptResult = [];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MemberLocation', () {
    test('isExpired returns true for past expiresAt', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(hours: 25)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        receivedAt: null,
      );
      expect(loc.isExpired, isTrue);
    });

    test('isExpired returns false for future expiresAt', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        receivedAt: null,
      );
      expect(loc.isExpired, isFalse);
    });
  });

  group('MemberLocation freshness rank', () {
    // A peer supplies its own `timestamp`, so nothing bounds it from above.
    // Ranking on it alone let a clock-ahead peer PIN its own marker: every
    // honest later fix compared older and was discarded until wall-clock
    // caught up. The rank is bounded by the receipt instant instead — and only
    // the rank, never what is stored or displayed.
    final at = DateTime.utc(2026, 9, 21, 12);

    MemberLocation fix({
      required Duration senderOffset,
      required Duration receiptOffset,
      double latitude = 0,
    }) => MemberLocation(
      pubkey: 'peer',
      latitude: latitude,
      longitude: 0,
      geohash: '9q8',
      timestamp: at.add(senderOffset),
      expiresAt: at.add(senderOffset + const Duration(minutes: 4)),
      receivedAt: at.add(receiptOffset),
    );

    test('a future-dated fix ranks at the instant it arrived', () {
      final ahead = fix(
        senderOffset: const Duration(hours: 1),
        receiptOffset: Duration.zero,
      );
      expect(ahead.freshness, at);
      expect(
        ahead.timestamp,
        at.add(const Duration(hours: 1)),
        reason: 'the sender reading itself is kept verbatim, never clamped',
      );
    });

    test('an honest fix ranks at its own timestamp', () {
      final honest = fix(
        senderOffset: const Duration(minutes: -3),
        receiptOffset: Duration.zero,
      );
      expect(honest.freshness, at.subtract(const Duration(minutes: 3)));
    });

    test('a later honest fix outranks an hour-ahead one', () {
      final ahead = fix(
        senderOffset: const Duration(hours: 1),
        receiptOffset: Duration.zero,
      );
      final honest = fix(
        senderOffset: const Duration(seconds: 10),
        receiptOffset: const Duration(seconds: 10),
      );
      expect(honest.outranks(ahead), isTrue);
      expect(
        ahead.isFresherThan(honest),
        isFalse,
        reason: 'as two already-ranked rows — the hydration question — the '
            'hour-ahead one is pinned at its arrival and loses',
      );
    });

    test('an arriving fix stamped before the stored row still wins', () {
      // Only the receiver's own clock stepping back can produce this, and the
      // arrival is later in reality, so it must replace what is there. Ranking
      // it below the stored row would drop the peer's whole stream until the
      // clock recovered — permanently, since each message is delivered once.
      final stored = fix(
        senderOffset: Duration.zero,
        receiptOffset: Duration.zero,
      );
      final afterStep = fix(
        senderOffset: const Duration(seconds: 10),
        receiptOffset: const Duration(minutes: -10),
      );
      expect(afterStep.outranks(stored), isTrue);
    });

    test('a replayed old fix never outranks a fresher live one', () {
      // The convergence replay delivers genuinely old fixes late: ranking on
      // arrival ALONE would let this one overwrite the live row.
      final live = fix(
        senderOffset: Duration.zero,
        receiptOffset: Duration.zero,
      );
      final replayed = fix(
        senderOffset: const Duration(minutes: -20),
        receiptOffset: const Duration(minutes: 5),
      );
      expect(replayed.outranks(live), isFalse);
    });

    test('a rank tie breaks on the sender reading', () {
      // Both future-dated and admitted at the same instant — receipt order
      // cannot separate them, so the sender's own ordering decides.
      final earlier = fix(
        senderOffset: const Duration(hours: 1),
        receiptOffset: Duration.zero,
      );
      final later = fix(
        senderOffset: const Duration(hours: 2),
        receiptOffset: Duration.zero,
      );
      expect(later.freshness, earlier.freshness);
      expect(later.outranks(earlier), isTrue);
      expect(earlier.outranks(later), isFalse);
    });

    test('re-delivery of the same fix does not outrank itself', () {
      final first = fix(
        senderOffset: Duration.zero,
        receiptOffset: Duration.zero,
      );
      final redelivered = fix(
        senderOffset: Duration.zero,
        receiptOffset: const Duration(minutes: 2),
      );
      expect(redelivered.outranks(first), isFalse);
    });

    test('an unknown receipt instant ranks on the sender reading alone', () {
      final base = MemberLocation(
        pubkey: 'peer',
        latitude: 0,
        longitude: 0,
        geohash: '9q8',
        timestamp: at.add(const Duration(hours: 1)),
        expiresAt: at,
        receivedAt: null,
      );
      expect(base.freshness, base.timestamp);
    });

    test('copyWith carries the receipt instant', () {
      final named = fix(
        senderOffset: const Duration(hours: 1),
        receiptOffset: Duration.zero,
      ).copyWith(displayName: 'Alice');
      expect(named.receivedAt, at);
      expect(
        named.freshness,
        at,
        reason: 'dropping it on copy would restore the pin for any row that '
            'later picks up a petname',
      );
    });
  });

  group('DecryptedLocation', () {
    test('isExpired works correctly', () {
      final expired = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37,
        longitude: -122,
        geohash: '9q8',
        timestamp: DateTime.now().subtract(const Duration(hours: 25)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
      );
      expect(expired.isExpired, isTrue);

      final valid = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37,
        longitude: -122,
        geohash: '9q8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
      );
      expect(valid.isExpired, isFalse);
    });
  });

  group('EncryptedLocation', () {
    test('creates with required fields', () {
      const loc = EncryptedLocation(
        eventJson: '{"id":"test","kind":445}',
        nostrGroupId: [1, 2, 3],
        relays: ['wss://relay.example.com'],
      );
      expect(loc.eventJson, contains('445'));
      expect(loc.nostrGroupId, hasLength(3));
      expect(loc.relays, contains('wss://relay.example.com'));
    });
  });

  group('LocationSharingService', () {
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

    group('publishLocation', () {
      test('seals through the core, then makes its one send', () async {
        final outcome = await service.publishLocation(
          mlsGroupId: [1, 2, 3],
          nostrGroupId: [4, 5, 6],
          latitude: 37.7749,
          longitude: -122.4194,
        );

        expect(
          mockCircleService.methodCalls,
          containsAllInOrder(['sealLocation', 'publishSealedLocation']),
        );
        expect(
          mockRelayService.methodCalls,
          isEmpty,
          reason: 'a location is sent by the core alone, to the relays its '
              'record names — never by a Dart relay ladder',
        );
        expect(outcome, isA<LocationPublishSent>());
      });

      test('every send answer maps to the outcome it means', () async {
        // The retention a receiver trusts (228 s from the group component)
        // is stamped by the core's seal, no longer by an interval this side
        // passed: `haven-core/src/nostr/mls/retention.rs`
        // `an_unstamped_application_message_becomes_stamped`.
        final mapped = <LocationPublishFfi, String>{};
        for (final answer in LocationPublishFfi.values) {
          mockCircleService.publishAnswers = [answer];
          final outcome = await service.publishLocation(
            mlsGroupId: [1, 2, 3],
            nostrGroupId: [4, 5, 6],
            latitude: 1,
            longitude: 2,
          );
          mockCircleService.publishAnswers = [];
          mapped[answer] = switch (outcome) {
            LocationPublishSent(acked: true) => 'acked',
            LocationPublishSent(acked: false) => 'not acked',
            LocationPublishDeferred() => 'held',
            LocationPublishInFlight() => 'in flight',
          };
        }

        expect(mapped, {
          LocationPublishFfi.accepted: 'acked',
          LocationPublishFfi.refused: 'not acked',
          LocationPublishFfi.unreachable: 'not acked',
          LocationPublishFfi.clockAhead: 'not acked',
          LocationPublishFfi.clockBehind: 'not acked',
          LocationPublishFfi.clockUnspecified: 'not acked',
          // Not sent: nothing reached a relay.
          LocationPublishFfi.expired: 'held',
          LocationPublishFfi.superseded: 'held',
          LocationPublishFfi.ended: 'held',
          LocationPublishFfi.inFlight: 'in flight',
        });
      });

      test('a held seal is returned typed and sends nothing', () async {
        mockCircleService.holdNextSeal = true;

        final outcome = await service.publishLocation(
          mlsGroupId: [1, 2, 3],
          nostrGroupId: [4, 5, 6],
          latitude: 1,
          longitude: 2,
        );

        expect(outcome, isA<LocationPublishDeferred>());
        expect(
          mockCircleService.methodCalls,
          isNot(contains('publishSealedLocation')),
        );
      });

      test('no seal or send log line names the circle or a relay', () async {
        final logs = LogCapture.install();
        mockCircleService.holdNextSeal = true;
        await service.publishLocation(
          mlsGroupId: [0xab, 1, 2],
          nostrGroupId: [0xcd, 4, 5],
          latitude: 37.7749,
          longitude: -122.4194,
        );
        mockCircleService.publishAnswers = [LocationPublishFfi.clockAhead];
        await service.publishLocation(
          mlsGroupId: [0xab, 1, 2],
          nostrGroupId: [0xcd, 4, 5],
          latitude: 37.7749,
          longitude: -122.4194,
        );

        logs
          ..assertContains('[LocationService] send held: nothing sealed')
          ..assertContains('[LocationService] publish done')
          ..assertNoNeedles([
            'ab0102',
            'cd0405',
            // The ids as Dart renders a raw byte list.
            '171, 1, 2',
            '205, 4, 5',
            '37.7749',
            '122.4194',
            'wss://relay.example.com',
          ]);
      });
    });

    group('fetchMemberLocations', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        members: [
          TestCircleFactory.createMember(
            pubkey: 'sender1',
            displayName: 'Alice',
          ),
        ],
      );

      test('returns empty for non-accepted circle', () async {
        final pendingCircle = TestCircleFactory.createCircle(
          membershipStatus: MembershipStatus.pending,
        );

        final result = await service.fetchMemberLocations(
          circle: pendingCircle,
        );

        expect(result.locations, isEmpty);
        expect(mockRelayService.methodCalls, isEmpty);
      });

      test('asks no relay for a disbanded circle', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService();
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(
          circle: TestCircleFactory.createCircle(
            engineState: CircleEngineState.disbanded,
          ),
        );

        expect(result.locations, isEmpty);
        expect(
          mockRelay.methodCalls,
          isEmpty,
          reason: "a disbanded circle's routing id is unlisted: a fetch for "
              'it would hand a relay the group a disband ended',
        );
        expect(mockCircle.methodCalls, isEmpty);
      });

      test('fetches and decrypts locations', () async {
        // Set up mock relay to return event JSONs
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.7749,
                longitude: -122.4194,
                geohash: '9q8yyk8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.locations, hasLength(1));
        expect(result.locations.first.latitude, 37.7749);
        expect(result.locations.first.displayName, 'Alice');
        expect(mockRelay.methodCalls, contains('fetchGroupMessages'));
        expect(mockCircle.methodCalls, contains('decryptLocation'));
      });

      test('a stop that lands while the fetch is still reading the store '
          'sends no relay request', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"${'c1' * 32}","kind":445}'],
        );
        final mockCircle = MockCircleService();
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(
          circle: testCircle,
          stopped: () =>
              mockCircle.methodCalls.contains('snapshotLastKnownForCircle'),
        );

        expect(
          mockCircle.methodCalls,
          contains('snapshotLastKnownForCircle'),
          reason: 'premise: the stop landed inside the hydrate',
        );
        expect(mockRelay.methodCalls, isNot(contains('fetchGroupMessages')));
        expect(result.locations, isEmpty);
      });

      test('a stop read inside the first ingest takes in no second event, '
          'writes no poll floor, and its log line names nothing', () async {
        final logs = LogCapture.install();
        final groupId = List<int>.generate(32, (i) => 0xa0 + i % 16);
        final circle = TestCircleFactory.createCircle(
          mlsGroupId: groupId,
          nostrGroupId: groupId,
          relays: const ['wss://planted.example'],
        );
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"${'c1' * 32}","kind":445,"created_at":1700000100}',
            '{"id":"${'c2' * 32}","kind":445,"created_at":1700000200}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [noDecryptResult, noDecryptResult];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(
          circle: circle,
          stopped: () => mockCircle.decryptCallEventJsons.isNotEmpty,
        );

        expect(mockCircle.decryptCallEventJsons, hasLength(1));
        expect(result.locations, isEmpty);
        await svc.fetchMemberLocations(circle: circle);
        expect(
          mockRelay.groupMessageSinces.last,
          isNull,
          reason: 'the stopped fetch moved the floor past what it skipped',
        );
        final hex = groupId
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        logs
          ..assertContains('[LocationService] fetch aborted — stopped mid-loop')
          ..assertNoNeedles([
            hex,
            'wss://planted.example',
            'c1' * 32,
            'c2' * 32,
          ]);
      });

      test('skips null decrypt results', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"group-update"}'],
        );
        final mockCircle = MockCircleService();
        // Default decrypt returns null

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.locations, isEmpty);
      });

      test('reports groupUpdated when commit event is processed', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evt1","kind":445,"content":"commit"}',
            '{"id":"evt2","kind":445,"content":"location"}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            // First event is a group update (commit/proposal)
            fakeDecrypt(groupUpdated: true),
            // Second event is a location
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ]
          // A `groupUpdate` result triggers the post-commit eviction sweep
          // (the engine already applied the commit internally, so
          // `getMembers` is queried to prune anyone no longer present —
          // see `_evictDepartedMembers`). Sender1 must still be a current
          // member here, else the sweep would immediately evict the
          // location this test just asserts on.
          ..getMembersResults = [
            [TestCircleFactory.createMember(pubkey: 'sender1')],
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.groupUpdated, isTrue);
        expect(result.locations, hasLength(1));
        expect(result.locations.first.latitude, 37.0);
      });

      test('reports groupUpdated false when no commits', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"location"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.groupUpdated, isFalse);
        expect(result.locations, hasLength(1));
      });

      // ------------------------------------------------------------------
      // Group sync cursor: this poller writes NONE.
      //
      // It used to advance the persisted `group_445` cursor to the
      // high-water-mark `created_at` of the events it processed. That value is
      // chosen by whoever signed the outer kind:445 envelope and is
      // authenticated by nothing on the receive path, and a circle's `#h` is its
      // PUBLIC routing id — so any relay observer could mint an event dated
      // "now", push the persisted REQ floor to it, and strand every legitimate
      // event below it, permanently and across restarts.
      //
      // The whole path — the `CircleService` group-cursor advance and the FFI
      // wrapper beneath it — is deleted (the symbols are named nowhere so the
      // guard can ban the tokens flat); group cursors are advanced in Rust only,
      // from the local instant an observation window opened.
      // `scripts/ci/check_no_event_timestamp_cursor_advance.sh` keeps it
      // deleted. The tests below pin what this poller DOES own —
      // in-memory seen-marking — which is what the deleted cursor tests were
      // really exercising through the accumulator.
      // ------------------------------------------------------------------
      List<LocationEventResult> locationResult(String sender) => fakeDecrypt(
        location: DecryptedLocation(
          senderPubkey: sender,
          latitude: 37,
          longitude: -122,
          geohash: '9q8',
          timestamp: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 23)),
        ),
      );

      test('the location poll never asks for a cursor advance', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
            '{"id":"evtB","kind":445,"created_at":1700000200,"content":"commit"}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            locationResult('sender1'),
            fakeDecrypt(groupUpdated: true),
          ];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        await svc.fetchMemberLocations(circle: testCircle);

        expect(
          mockCircle.methodCalls.where((c) => c.contains('Cursor')),
          isEmpty,
          reason:
              'a fully-processed batch must move no sync cursor from this '
              'poller — the group cursor is anchored in Rust on a local clock '
              'reading, never on an inbound event timestamp',
        );
      });

      test(
        'an unprocessable event stays eligible for retry on the next poll',
        () async {
          // The property the deleted "never advances past an unprocessable
          // event" cursor test was really protecting: an event the engine did
          // not take in must not be marked seen, so the next poll re-attempts
          // it while the taken one is skipped. Since the driver's ingest that
          // is the engine's HOLD verdict, not an empty result: one it took in
          // with nothing to hand back yet is retained and replayed by the
          // engine itself.
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
              '{"id":"evtB","kind":445,"created_at":1700000200,"content":"unp"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              locationResult('sender1'), // evtA taken in
              noDecryptResult, // evtB held
              noDecryptResult, // evtB, retried on the second poll
            ]
            ..ingestHeld.addAll([1, 2]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          expect(mockCircle.decryptCallEventJsons, hasLength(2));

          await svc.fetchMemberLocations(circle: testCircle);
          expect(
            mockCircle.decryptCallEventJsons, hasLength(3),
            reason:
                'exactly ONE more decrypt: evtA was seen and is skipped, evtB '
                'failed and must be retried',
          );
          expect(mockCircle.decryptCallEventJsons.last, contains('evtB'));
        },
      );

      // ------------------------------------------------------------------
      // Wire-compat (plan D8 / protocol review 4.3): a legacy avatar-style
      // inner (or any other successfully-decrypted-but-not-a-location
      // content, e.g. a `haven-avatar-*` chunk from a pre-migration
      // client) must be treated as SEEN/SKIPPED, never as a retriable
      // decrypt failure. `CircleService.decryptLocation` surfaces this
      // shape as a non-null `DecryptResult` with `location: null` and
      // `groupUpdated: false` (mirrors the Rust FFI contract: the MLS
      // layer decrypted successfully — fully processed — but the content
      // isn't a `LocationMessage`).
      // ------------------------------------------------------------------
      test(
        'test_legacy_avatar_message_is_skipped_not_retried',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtAvatar","kind":445,"created_at":1700000300,'
                  '"content":"haven-avatar-chunk"}',
            ],
          );
          // Successfully decrypted at the MLS layer, but the content is not
          // a location (e.g. the legacy avatar wire) — non-null result,
          // location: null, groupUpdated: false.
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [fakeDecrypt()];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.locations, isEmpty);
          expect(result.groupUpdated, isFalse);

          // A second fetch (same relay contents) must NOT re-decrypt the
          // same event — proving it was recorded as seen rather than left
          // eligible for retry on every subsequent poll cycle.
          await svc.fetchMemberLocations(circle: testCircle);
          expect(
            mockCircle.decryptCallEventJsons,
            hasLength(1),
            reason:
                'the legacy avatar-content event must be decrypted exactly '
                'once — a subsequent fetch must skip it as already-seen, '
                'not re-attempt decryption on every poll cycle forever',
          );
        },
      );

      // The evolution poller (_runEvolutionPoll) had its OWN copy of the
      // deleted cursor accumulator; it must stay cursor-free too.
      test('the evolution poll asks no relay for a disbanded circle',
          () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evtA","kind":445,"content":"commit"}'],
        );
        final mockCircle = MockCircleService();
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final updated = await svc.pollEvolutionEvents(
          circles: [
            TestCircleFactory.createCircle(
              engineState: CircleEngineState.disbanded,
            ),
          ],
        );

        expect(updated, isFalse);
        expect(mockRelay.methodCalls, isEmpty);
        expect(mockCircle.methodCalls, isEmpty);
      });

      test('the evolution poll never asks for a cursor advance', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
            '{"id":"evtB","kind":445,"created_at":1700000200,"content":"commit"}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            locationResult('sender1'),
            fakeDecrypt(groupUpdated: true),
          ];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        await svc.pollEvolutionEvents(circles: [testCircle]);

        expect(
          mockCircle.methodCalls.where((c) => c.contains('Cursor')),
          isEmpty,
          reason:
              'the evolution poll must move no sync cursor either — same '
              'unauthenticated-timestamp argument as the location poll',
        );
      });

      // The receive-side auto-commit for a peer's `SelfRemove` was run here,
      // in Dart, by the ladder the group that stood here pinned. Both polls
      // now ingest through the fanout driver, which records and drives that
      // commit in Rust (`haven-core/tests/poll_send_drive_e2e.rs`: the test
      // whose name begins
      // `a_removal_owed_after_a_departure_is_published_promptly`, which runs
      // the full mode a foreground poll's `foreground: true` gives, and, for
      // what its confirm replays, the one beginning
      // `a_fix_replayed_inside_a_poll_plane_confirm`). What Dart still owns
      // is the hold.
      group('an event the engine holds (Rule 12)', () {
        const held = '{"id":"evtHeld","kind":445,"created_at":1700000100}';
        final heldAt = DateTime.fromMillisecondsSinceEpoch(
          1700000100 * 1000,
          isUtc: true,
        );

        test('is fetched again, and the poll floor does not move past it',
            () async {
          final mockRelay = MockRelayService(groupMessages: [held]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult, noDecryptResult]
            ..ingestHeld.addAll([0, 1]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          await svc.fetchMemberLocations(circle: testCircle);

          expect(mockCircle.decryptCallEventJsons, [held, held]);
          // Before: the floor stayed where it was (here: no floor, every poll
          // re-fetching the circle's whole history). It now anchors at the
          // held event's own instant, so it stays inside the next query.
          expect(mockRelay.groupMessageSinces.first, isNull);
          expect(
            mockRelay.groupMessageSinces.last!.isAfter(heldAt),
            isFalse,
            reason: 'the floor moved past an event the engine still holds',
          );
        });

        test('a thrown ingest is held the same way', () async {
          final mockRelay = MockRelayService(groupMessages: [held]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult, noDecryptResult]
            ..ingestThrowsAt.addAll([0, 1]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          await svc.fetchMemberLocations(circle: testCircle);

          expect(mockCircle.decryptCallEventJsons, [held, held]);
          expect(mockRelay.groupMessageSinces.last!.isAfter(heldAt), isFalse);
        });

        test('the evolution poll holds a thrown ingest too', () async {
          final mockRelay = MockRelayService(groupMessages: [held]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult, noDecryptResult]
            ..ingestThrowsAt.addAll([0, 1]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.pollEvolutionEvents(circles: [testCircle]);
          await svc.pollEvolutionEvents(circles: [testCircle]);

          expect(mockCircle.decryptCallEventJsons, [held, held]);
          expect(mockRelay.groupMessageSinces.last!.isAfter(heldAt), isFalse);
        });

        test('an event taken in is never asked for again, whatever it '
            'handed back', () async {
          // Before: an event that folded no result was decrypted again on
          // every poll. The engine's verdict, not the result count, says
          // whether it was taken in.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evtTaken","kind":445}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          await svc.fetchMemberLocations(circle: testCircle);

          expect(mockCircle.decryptCallEventJsons, hasLength(1));
          expect(mockRelay.groupMessageSinces.last, isNotNull);
        });

        test('the evolution poll holds its floor behind it too', () async {
          final mockRelay = MockRelayService(groupMessages: [held]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult, noDecryptResult]
            ..ingestHeld.addAll([0, 1]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.pollEvolutionEvents(circles: [testCircle]);
          await svc.pollEvolutionEvents(circles: [testCircle]);

          expect(mockCircle.decryptCallEventJsons, [held, held]);
          expect(mockRelay.groupMessageSinces.first, isNull);
          expect(mockRelay.groupMessageSinces.last!.isAfter(heldAt), isFalse);
        });

        test('no hold log line names the event, the circle or a relay',
            () async {
          final logs = LogCapture.install();
          final eventId = 'ab' * 32;
          final heldEvent =
              '{"id":"$eventId","kind":445,"created_at":1700000100}';
          final mockRelay = MockRelayService(groupMessages: [heldEvent]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [noDecryptResult, noDecryptResult]
            ..ingestHeld.addAll([0, 1]);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          await svc.pollEvolutionEvents(circles: [testCircle]);

          logs
            ..assertContains('[LocationService] evt=')
            ..assertContains('→ held')
            ..assertContains(' held')
            ..assertContains('[EvolutionPoller] evt=')
            ..assertNoNeedles([
              eventId,
              testCircle.nostrGroupId
                  .map((b) => b.toRadixString(16).padLeft(2, '0'))
                  .join(),
              ...testCircle.relays,
            ]);
        });

        test('a location a held event handed back still reaches the cache',
            () async {
          final mockRelay = MockRelayService(groupMessages: [held]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [locationResult('sender1')]
            ..ingestHeld.add(0);
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.locations.map((l) => l.pubkey), ['sender1']);
        });
      });

      test(
        'returns expired locations within eviction grace as stale',
        () async {
          // Entries that are expired but within [cacheEvictionGrace] past
          // their `expiresAt` are retained so the UI can fall back to a
          // faded "last known" marker. Eviction only removes entries
          // stale enough that the persistent store has already assumed
          // ownership.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"expired"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now().subtract(
                    const Duration(minutes: 40),
                  ),
                  expiresAt: DateTime.now().subtract(
                    const Duration(minutes: 10),
                  ),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.locations, hasLength(1));
          expect(result.locations.first.isExpired, isTrue);
        },
      );

      test('deduplicates by sender keeping latest', () async {
        final now = DateTime.now();
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evt1","kind":445,"content":"old"}',
            '{"id":"evt2","kind":445,"content":"new"}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(minutes: 5)),
                expiresAt: now.add(const Duration(hours: 23)),
              ),
            ),
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 38,
                longitude: -121,
                geohash: '9q9',
                timestamp: now,
                expiresAt: now.add(const Duration(hours: 23)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.locations, hasLength(1));
        expect(result.locations.first.latitude, 38.0); // Latest one
      });

      test('handles decryption errors gracefully', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evt1","kind":445,"content":"will-fail"}',
            '{"id":"evt2","kind":445,"content":"will-succeed"}',
          ],
        );
        // Create a custom circle service that throws on first decrypt
        final throwingService = _ThrowOnFirstDecryptService();

        final svc = LocationSharingService(
          circleService: throwingService,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        // Should have the second location (first one threw)
        expect(result.locations, hasLength(1));
        expect(result.locations.first.latitude, 38.0);
      });

      test('cached locations persist across fetch cycles', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.7749,
                longitude: -122.4194,
                geohash: '9q8yyk8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        // First fetch — decrypts and caches
        final first = await svc.fetchMemberLocations(circle: testCircle);
        expect(first.locations, hasLength(1));
        expect(first.locations.first.latitude, 37.7749);

        // Second fetch — same event returned by relay, but already in
        // _seenEventIds so decrypt is skipped. Cached location persists.
        final second = await svc.fetchMemberLocations(circle: testCircle);
        expect(second.locations, hasLength(1));
        expect(second.locations.first.latitude, 37.7749);

        // decryptLocation should only be called once (dedup by event ID)
        final decryptCalls = mockCircle.methodCalls.where(
          (c) => c == 'decryptLocation',
        );
        expect(decryptCalls, hasLength(1));
      });

      test('new events update cached locations', () async {
        final now = DateTime.now();
        final mockRelay = _MutableMockRelayService(
          initialMessages: ['{"id":"evt1","kind":445,"content":"first"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: now,
                expiresAt: now.add(const Duration(hours: 23)),
              ),
            ),
            // Second decrypt result for the new event
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 38,
                longitude: -121,
                geohash: '9q9',
                timestamp: now.add(const Duration(minutes: 5)),
                expiresAt: now.add(const Duration(hours: 23)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        // First fetch
        final first = await svc.fetchMemberLocations(circle: testCircle);
        expect(first.locations, hasLength(1));
        expect(first.locations.first.latitude, 37.0);

        // Simulate a new event appearing on relay
        mockRelay.addMessage('{"id":"evt2","kind":445,"content":"second"}');

        // Second fetch — new event decrypted and updates cache
        final second = await svc.fetchMemberLocations(circle: testCircle);
        expect(second.locations, hasLength(1));
        expect(second.locations.first.latitude, 38.0); // Updated
      });

      test('expired locations are retained in cache as stale', () async {
        // Eviction is now driven by the persistent store's purge_after
        // column (sender-controlled retention). The in-memory cache keeps
        // expired entries so the map can fall back to "last known" data.
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"expiring"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(hours: 25)),
                expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);
        expect(result.locations, hasLength(1));
        expect(result.locations.first.isExpired, isTrue);
      });
    });

    group('cache bounds', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        members: [
          TestCircleFactory.createMember(
            pubkey: 'sender1',
            displayName: 'Alice',
          ),
        ],
      );

      test('evicts entries past the configured grace period', () async {
        // Entry expired 1h ago — with a 15min grace, it should be
        // evicted after fetch completes.
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"stale"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(hours: 2)),
                expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
          cacheEvictionGrace: const Duration(minutes: 15),
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(
          result.locations,
          isEmpty,
          reason: 'entry past grace should be evicted before return',
        );
        expect(svc.debugCachedLocationCount, 0);
      });

      test('retains entries within the grace period', () async {
        // Entry expired 5min ago — with a 30min grace, should be retained.
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"fresh-enough"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(minutes: 35)),
                expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
              ),
            ),
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.locations, hasLength(1));
        expect(svc.debugCachedLocationCount, 1);
      });

      test('_seenEventIds is FIFO-capped at maxSeenEventIds', () async {
        // Configure a tiny cap of 3 and feed 5 events. After the fetch,
        // the set should contain exactly the 3 most recent IDs.
        final events = List.generate(
          5,
          (i) => '{"id":"evt$i","kind":445,"content":"c$i"}',
        );
        final mockRelay = MockRelayService(groupMessages: events);
        // `fakeDecrypt(groupUpdated: true)` is the minimal non-null
        // payload: it marks the event as successfully processed (so
        // `_seenEventIds` is populated under the mark-after-success
        // rule) without producing a cached location. Exactly what the
        // dedup-cap test wants to exercise.
        final mockCircle = MockCircleService()
          ..decryptLocationResults = List.filled(
            5,
            fakeDecrypt(groupUpdated: true),
          );

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
          maxSeenEventIds: 3,
        );

        await svc.fetchMemberLocations(circle: testCircle);

        expect(
          svc.debugSeenEventIdsCount,
          3,
          reason: 'cap should hold after 5 insertions',
        );
      });

      test(
        're-fetching a batch that fits within the cap causes no re-decrypts',
        () async {
          // The cap (10) comfortably exceeds the batch size (5), so after
          // the first fetch all 5 IDs live in the seen-set. A second
          // relay fetch returning the same 5 events must short-circuit
          // at the dedup gate and never re-enter decrypt.
          final events = List.generate(
            5,
            (i) => '{"id":"evt$i","kind":445,"content":"c$i"}',
          );
          final mockRelay = MockRelayService(groupMessages: events);
          // Non-null results so each event is marked seen under the
          // mark-after-success dedup rule.
          final mockCircle = MockCircleService()
            ..decryptLocationResults = List.filled(
              5,
              fakeDecrypt(groupUpdated: true),
            );

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
            maxSeenEventIds: 10,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          await svc.fetchMemberLocations(circle: testCircle);

          final decryptCalls = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(
            decryptCalls,
            5,
            reason: 'second pass must be fully absorbed by the seen set',
          );
          expect(svc.debugSeenEventIdsCount, 5);
        },
      );

      test(
        'entry just inside the grace window is retained (strict <)',
        () async {
          // Review-driven: the eviction check uses `isBefore(cutoff)`,
          // so an entry whose `expiresAt` is at-or-after the cutoff
          // must be retained. Without this test a future sign flip to
          // `<=` goes undetected.
          //
          // We can't set `expiresAt == cutoff` exactly: `_evictStaleLocations`
          // re-reads `DateTime.now()`, which advances a few µs between
          // setup and eviction and would flip a boundary-exact entry to
          // the evicted side. Nudge 500 ms inside the grace window so
          // drift is absorbed while the boundary semantic is still
          // exercised — a `<=` flip would evict anything up to this
          // offset and fail the test.
          const grace = Duration(minutes: 10);
          const boundaryNudge = Duration(milliseconds: 500);
          final now = DateTime.now();
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"boundary"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: now.subtract(const Duration(minutes: 30)),
                  // 500 ms inside the grace cutoff → retained under `<`,
                  // would still be retained under a theoretical `<=`, but
                  // a `<=` flip combined with re-reading `DateTime.now()`
                  // in eviction would consistently evict; if we ever tune
                  // the test, anything <=0 nudge is unstable.
                  expiresAt: now.subtract(grace).add(boundaryNudge),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
            cacheEvictionGrace: grace,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);
          expect(result.locations, hasLength(1));
        },
      );

      test(
        'cacheEvictionGrace: Duration.zero evicts anything past expiry',
        () async {
          // Zero-grace is explicitly allowed by the constructor assert
          // (`>= Duration.zero`). Anything with an `expiresAt` before
          // `now` must be evicted on the same fetch that decrypted it.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"past"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now().subtract(
                    const Duration(seconds: 2),
                  ),
                  expiresAt: DateTime.now().subtract(
                    const Duration(seconds: 1),
                  ),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
            cacheEvictionGrace: Duration.zero,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);
          expect(result.locations, isEmpty);
          expect(svc.debugCachedLocationCount, 0);
        },
      );

      test(
        'multi-circle eviction is independent — stale in A preserves fresh in B',
        () async {
          // Populate two circles. Circle A receives a past-grace entry
          // (must be evicted). Circle B receives a fresh entry. A
          // fetch on A must not touch B's cache.
          final now = DateTime.now();
          final circleA = TestCircleFactory.createCircle(
            displayName: 'A',
            // Distinct MLS + Nostr group IDs so the per-circle cache
            // keys differ.
            mlsGroupId: const [0xAA, 0x01],
            nostrGroupId: const [0xAA, 0x01],
            members: [
              TestCircleFactory.createMember(
                pubkey: 'senderA',
                displayName: 'Alice',
              ),
            ],
          );
          final circleB = TestCircleFactory.createCircle(
            displayName: 'B',
            mlsGroupId: const [0xBB, 0x02],
            nostrGroupId: const [0xBB, 0x02],
            members: [
              TestCircleFactory.createMember(
                pubkey: 'senderB',
                displayName: 'Bob',
              ),
            ],
          );

          final mockRelay = _MutableMockRelayService(
            initialMessages: ['{"id":"evtB","kind":445,"content":"fresh"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'senderB',
                  latitude: 40,
                  longitude: -100,
                  geohash: '9yz',
                  timestamp: now,
                  expiresAt: now.add(const Duration(hours: 23)),
                ),
                mlsGroupId: circleB.mlsGroupId,
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
            cacheEvictionGrace: const Duration(minutes: 15),
          );

          // Seed B with a fresh entry via a normal fetch cycle.
          final fetchedB = await svc.fetchMemberLocations(circle: circleB);
          expect(fetchedB.locations, hasLength(1));
          expect(svc.debugCachedLocationCount, 1);

          // Now feed A with a past-grace entry via a second fetch on A.
          mockCircle.decryptLocationResults = [
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'senderA',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(hours: 2)),
                expiresAt: now.subtract(const Duration(hours: 1)),
              ),
              mlsGroupId: circleA.mlsGroupId,
            ),
          ];
          mockRelay.replaceAll(['{"id":"evtA","kind":445,"content":"stale"}']);

          final fetchedA = await svc.fetchMemberLocations(circle: circleA);
          expect(
            fetchedA.locations,
            isEmpty,
            reason: "A's past-grace entry must be evicted",
          );

          // B's cache must remain intact — fetching A must not touch B.
          expect(
            svc.debugCachedLocationCount,
            1,
            reason: "only B's fresh entry should remain",
          );
        },
      );

      test('interleaved fetches preserve FIFO ordering across calls', () async {
        // Fetch 1: evt0, evt1 at cap=3 → set = {evt0, evt1}.
        // Fetch 2: evt2, evt3    → insert evt2 (size 3), insert evt3
        //                          (size 4 → evict evt0) → set =
        //                          {evt1, evt2, evt3}.
        // Asserts that the *oldest* ID (evt0) is what FIFO evicts,
        // not the newest — the property a broken LRU would get wrong.
        // Non-null results for the 4 fetches that should mark seen.
        // The trailing null in the third fetch (re-feeding evt0) is
        // deliberate — the mock returns null once the index exhausts
        // this list, so we observe an unmarked-on-null decrypt on
        // retry, proving evt0 was truly evicted (not simply marked
        // and re-returned).
        final mockCircle = MockCircleService()
          ..decryptLocationResults = List.filled(
            4,
            fakeDecrypt(groupUpdated: true),
          );

        final mockRelay = _MutableMockRelayService(
          initialMessages: [
            '{"id":"evt0","kind":445,"content":"c0"}',
            '{"id":"evt1","kind":445,"content":"c1"}',
          ],
        );

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
          maxSeenEventIds: 3,
        );

        await svc.fetchMemberLocations(circle: testCircle);
        expect(svc.debugSeenEventIdsCount, 2);

        // Replace relay payload for the next fetch with the two new
        // events only.
        mockRelay.replaceAll([
          '{"id":"evt2","kind":445,"content":"c2"}',
          '{"id":"evt3","kind":445,"content":"c3"}',
        ]);

        await svc.fetchMemberLocations(circle: testCircle);

        expect(svc.debugSeenEventIdsCount, 3);

        // Re-feed evt0 only — it should NOT be in the seen set
        // (was the oldest and got FIFO-evicted). Re-processing it
        // should be observable as +1 decrypt call.
        final decryptsBefore = mockCircle.methodCalls
            .where((c) => c == 'decryptLocation')
            .length;
        mockCircle.decryptLocationResults = [noDecryptResult];
        mockRelay.replaceAll(['{"id":"evt0","kind":445,"content":"c0"}']);
        await svc.fetchMemberLocations(circle: testCircle);
        final decryptsAfter = mockCircle.methodCalls
            .where((c) => c == 'decryptLocation')
            .length;
        expect(
          decryptsAfter - decryptsBefore,
          1,
          reason: 'evt0 was FIFO-evicted and must re-decrypt',
        );
      });

      test(
        'already-seen skip path suppresses decrypt independently of cache',
        () async {
          // Isolate the pre-decrypt seen-set short-circuit: feed the
          // same 3 events twice, with cap >> batch. The first pass
          // marks them seen (requires non-null decrypts under the
          // mark-after-success rule). The second pass must add zero
          // to the decrypt count.
          final mockRelay = MockRelayService(
            groupMessages: const [
              '{"id":"e0","kind":445,"content":"c0"}',
              '{"id":"e1","kind":445,"content":"c1"}',
              '{"id":"e2","kind":445,"content":"c2"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = List.filled(
              3,
              fakeDecrypt(groupUpdated: true),
            );

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
            // Huge cap — cannot evict within this test.
            maxSeenEventIds: 1 << 20,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          final firstCount = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(firstCount, 3);

          await svc.fetchMemberLocations(circle: testCircle);
          final secondCount = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(secondCount, 3, reason: 'no new decrypt calls on second pass');
          expect(svc.debugSeenEventIdsCount, 3);
        },
      );

      // ────────────────────────────────────────────────────────────
      // Regression tests for the cross-epoch retry bug where an
      // admin could not decrypt a newly-joined member's first
      // location. Root cause was a four-step composition:
      //
      //  1. Self-update fires on accept → member advances to epoch
      //     N+1 before first location publish.
      //  2. Relay returns newest-first in a single batch → the
      //     epoch-advancing commit (older `created_at`) arrives
      //     after the epoch-N+1 application message.
      //  3. The service marked events seen BEFORE decrypt → the
      //     application message was blacklisted even though its
      //     decrypt failed only because the local epoch hadn't
      //     advanced yet.
      //  4. No event-level retry on the next fetch.
      //
      // The minimal fix addresses links (2) + (3): sort ascending
      // by `created_at`, and mark events seen only after a
      // successful decrypt.
      // ────────────────────────────────────────────────────────────

      test(
        'a held event stays eligible for retry on the next fetch',
        () async {
          // First fetch's ingest is HELD by the engine (input it cannot take
          // in yet). The event must NOT be in the seen set afterwards. On
          // the second fetch with the same event, the engine takes it in and
          // the location surfaces.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"wrong-epoch"}'],
          );
          final mockCircle = MockCircleService()
            ..ingestHeld.add(0)
            ..decryptLocationResults = [
              // First attempt: wrong epoch → no result.
              noDecryptResult,
              // Second attempt: epoch has caught up → success.
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, isEmpty);
          expect(
            svc.debugSeenEventIdsCount,
            0,
            reason: 'a held event must not be marked seen',
          );

          final second = await svc.fetchMemberLocations(circle: testCircle);
          expect(
            second.locations,
            hasLength(1),
            reason: 'retry on the same event id must succeed',
          );
          expect(second.locations.first.latitude, 37.0);
          expect(
            svc.debugSeenEventIdsCount,
            1,
            reason: 'successful decrypt marks the event seen',
          );
          // Two decrypt calls total: one per fetch.
          final decryptCalls = mockCircle.methodCalls
              .where((c) => c == 'decryptLocation')
              .length;
          expect(decryptCalls, 2);
        },
      );

      test(
        'thrown decrypt error leaves the event eligible for retry on next fetch',
        () async {
          // Transient FFI hiccups (and upstream cache-write errors
          // in the decrypt path) must not blacklist an event. This
          // matches the White Noise reference which returns Err for
          // transient failures so the caller skips the mark-seen
          // step.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"flaky"}'],
          );
          final flakyService = _ThrowOnFirstDecryptService();

          final svc = LocationSharingService(
            circleService: flakyService,
            relayService: mockRelay,
          );

          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, isEmpty);
          expect(
            svc.debugSeenEventIdsCount,
            0,
            reason: 'thrown decrypt must not mark seen',
          );

          final second = await svc.fetchMemberLocations(circle: testCircle);
          expect(
            second.locations,
            hasLength(1),
            reason: 'retry after transient error must succeed',
          );
          expect(
            svc.debugSeenEventIdsCount,
            1,
            reason: 'successful retry marks the event seen',
          );
        },
      );

      test('events are decrypted in ascending `created_at` order', () async {
        // The relay hands us newest-first: the ApplicationMessage
        // with the later timestamp arrives before its
        // epoch-advancing Commit. The service must reorder them
        // so the Commit is processed first, otherwise the
        // ApplicationMessage would fail to decrypt (and under
        // mark-after-success, wait for the next fetch).
        //
        // We assert ordering by inspecting the `eventJson`s passed
        // to `decryptLocation` in call order.
        const commitEvent =
            '{"id":"commit1","kind":445,"created_at":1700000000,'
            '"content":"commit"}';
        const msgEvent =
            '{"id":"msg1","kind":445,"created_at":1700000100,'
            '"content":"msg"}';
        // Relay returns newest first (msgEvent then commitEvent) —
        // matches real Nostr relay behaviour.
        final mockRelay = MockRelayService(
          groupMessages: [msgEvent, commitEvent],
        );
        // The service will call decrypt in sorted (ascending) order,
        // so the first result is consumed by the commit and the
        // second by the application message.
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(groupUpdated: true),
            fakeDecrypt(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ]
          // Same as above: `groupUpdated` triggers the post-commit
          // eviction sweep, so sender1 must be a current member or the
          // sweep would immediately evict the location under test.
          ..getMembersResults = [
            [TestCircleFactory.createMember(pubkey: 'sender1')],
          ];

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.groupUpdated, isTrue);
        expect(result.locations, hasLength(1));
        // Critical: the decrypt call order must be (commit, msg),
        // not relay-order (msg, commit). A regression that skipped
        // the sort would flip these.
        expect(mockCircle.decryptCallEventJsons, [commitEvent, msgEvent]);
      });

      test(
        'events with missing `created_at` sort to the start (key = 0) and still decrypt',
        () async {
          // The malformed event has no `created_at`, so it gets key
          // 0 and sorts before the well-formed event (which has a
          // positive timestamp). Both are still processed in order
          // with no thrown exceptions — the fetch loop stays robust
          // in the presence of a diagnostic anomaly.
          const malformed = '{"id":"bad1","kind":445,"content":"no-ts"}';
          const valid =
              '{"id":"ok1","kind":445,"created_at":1700000000,'
              '"content":"ok"}';
          final mockRelay = MockRelayService(groupMessages: [valid, malformed]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(groupUpdated: true),
              fakeDecrypt(groupUpdated: true),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          // Two successful decrypts → both marked seen.
          expect(svc.debugSeenEventIdsCount, 2);
          expect(result.groupUpdated, isTrue);
          // Malformed (key=0) sorts ahead of valid (key=1700000000).
          expect(mockCircle.decryptCallEventJsons, [malformed, valid]);
        },
      );

      test(
        'events sharing a `created_at` keep their relay-provided order (stable tiebreak)',
        () async {
          // When multiple events legitimately share a timestamp
          // (e.g., a burst from the same sender in the same second),
          // the sort must be stable so behaviour is deterministic
          // across runs. We rely on the tiebreak-on-original-index
          // clause in `fetchMemberLocations`.
          const e1 = '{"id":"e1","kind":445,"created_at":1700000000,"c":"a"}';
          const e2 = '{"id":"e2","kind":445,"created_at":1700000000,"c":"b"}';
          const e3 = '{"id":"e3","kind":445,"created_at":1700000000,"c":"c"}';
          final mockRelay = MockRelayService(groupMessages: [e1, e2, e3]);
          final mockCircle = MockCircleService()
            ..decryptLocationResults = List.filled(
              3,
              fakeDecrypt(groupUpdated: true),
            );

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);

          expect(mockCircle.decryptCallEventJsons, [e1, e2, e3]);
        },
      );
    });

    group('departed member eviction (Fix #2)', () {
      // Shared circle: self + alice + bob. Bob will be the departing member.
      // Uses distinct MLS group ID [10,20,30,40] and Nostr group ID [50,60,70,80].
      final evictionCircle = TestCircleFactory.createCircle(
        mlsGroupId: const [10, 20, 30, 40],
        nostrGroupId: const [50, 60, 70, 80],
        displayName: 'Eviction Test',
        members: [
          TestCircleFactory.createMember(pubkey: 'selfpubkey', isAdmin: true),
          TestCircleFactory.createMember(
            pubkey: 'alicepubkey',
            displayName: 'Alice',
          ),
          TestCircleFactory.createMember(
            pubkey: 'bobpubkey',
            displayName: 'Bob',
          ),
        ],
      );

      // Returns a future-expiry DecryptedLocation for the given pubkey.
      DecryptedLocation locFor(String pubkey) => DecryptedLocation(
        senderPubkey: pubkey,
        latitude: 37,
        longitude: -122,
        geohash: '9q8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
      );

      // Helper: builds a LocationSharingService pre-seeded with alice + bob
      // in the in-memory cache and returns it alongside the mutable relay so
      // Phase 2 can replace the relay's message list with the proposal/commit
      // event. The mock's result indices are reset after Phase 1 so Phase 2
      // can assign fresh result lists starting at index 0.
      Future<
        ({
          LocationSharingService svc,
          MockCircleService circle,
          _MutableMockRelayService relay,
        })
      >
      buildSeededService() async {
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            fakeDecrypt(
              location: locFor('alicepubkey'),
              mlsGroupId: evictionCircle.mlsGroupId,
            ),
            fakeDecrypt(
              location: locFor('bobpubkey'),
              mlsGroupId: evictionCircle.mlsGroupId,
            ),
          ];
        final relay = _MutableMockRelayService(
          initialMessages: [
            '{"id":"alice-loc","kind":445,"content":"a"}',
            '{"id":"bob-loc","kind":445,"content":"b"}',
          ],
        );
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: relay,
        );
        await svc.fetchMemberLocations(circle: evictionCircle);
        // Reset sequential-result indices so Phase 2 can set fresh lists
        // starting at index 0 without fighting Phase 1's consumed cursor.
        mockCircle.resetResultIndices();
        return (svc: svc, circle: mockCircle, relay: relay);
      }

      test(
        'evicts departed member from in-memory cache on group update',
        () async {
          final (:svc, :circle, :relay) = await buildSeededService();
          expect(svc.debugCachedLocationCount, 2);

          // Phase 2: relay delivers the group-changing event that removes
          // bob. The engine applies it internally, so getMembers reflects
          // the post-change roster by the time decrypt returns.
          relay.replaceAll([
            '{"id":"proposal","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              fakeDecrypt(
                groupUpdated: true,
                mlsGroupId: const [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
              ],
            ];

          final result = await svc.fetchMemberLocations(circle: evictionCircle);

          // Bob's entry must be gone from the in-memory cache.
          expect(
            result.locations.map((l) => l.pubkey),
            isNot(contains('bobpubkey')),
            reason: 'bob left — his pin must be evicted immediately',
          );
          expect(svc.debugCachedLocationCount, 1, reason: 'only alice remains');
          // getMembers was called to determine the post-commit roster.
          expect(circle.methodCalls, contains('getMembers'));
        },
      );

      test(
        'evicts persistent last-known-location for departed member',
        () async {
          // buildSeededService already upserts alice + bob into the mock
          // persistent store (via upsertLastKnownLocation in Phase 1).
          final (:svc, :circle, :relay) = await buildSeededService();
          expect(svc.debugCachedLocationCount, 2);

          // Both alice and bob have a persistent row from Phase 1.
          final aliceRowsBefore = circle.lastKnownRows
              .where((r) => r['senderPubkey'] == 'alicepubkey')
              .length;
          final bobRowsBefore = circle.lastKnownRows
              .where((r) => r['senderPubkey'] == 'bobpubkey')
              .length;
          expect(aliceRowsBefore, greaterThan(0));
          expect(bobRowsBefore, greaterThan(0));

          // Phase 2: deliver the group-changing event removing bob.
          relay.replaceAll([
            '{"id":"proposal","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              fakeDecrypt(
                groupUpdated: true,
                mlsGroupId: const [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
              ],
            ];
          await svc.fetchMemberLocations(circle: evictionCircle);

          // removeLastKnownMember must have been called for bob.
          expect(
            circle.methodCalls,
            contains('removeLastKnownMember'),
            reason: 'persistent last-known-location must be pruned for bob',
          );
          // Bob's rows must all be gone.
          final bobRowsAfter = circle.lastKnownRows
              .where((r) => r['senderPubkey'] == 'bobpubkey')
              .toList();
          expect(
            bobRowsAfter,
            isEmpty,
            reason: "bob's persistent last-known row must be removed",
          );
          // Alice's rows must remain (same count as before eviction).
          final aliceRowsAfter = circle.lastKnownRows
              .where((r) => r['senderPubkey'] == 'alicepubkey')
              .length;
          expect(aliceRowsAfter, equals(aliceRowsBefore));
        },
      );

      test(
        'does not evict when groupUpdated is true but no member change',
        () async {
          final (:svc, :circle, :relay) = await buildSeededService();
          expect(svc.debugCachedLocationCount, 2);

          // Deliver a group-state-changing event (e.g., a rename) with no
          // member change — getMembers returns alice + bob unchanged.
          relay.replaceAll([
            '{"id":"self-update-evt","kind":445,"content":"update"}',
          ]);
          circle
            ..decryptLocationResults = [
              fakeDecrypt(
                groupUpdated: true,
                mlsGroupId: const [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
                TestCircleFactory.createMember(
                  pubkey: 'bobpubkey',
                  displayName: 'Bob',
                ),
              ],
            ];
          await svc.fetchMemberLocations(circle: evictionCircle);

          // Both alice and bob must still be in cache.
          expect(
            svc.debugCachedLocationCount,
            2,
            reason: 'no member change — both entries must remain in cache',
          );
          // removeLastKnownMember must NOT have been called.
          expect(
            circle.methodCalls,
            isNot(contains('removeLastKnownMember')),
            reason: 'no departed member — persistent prune must not fire',
          );
        },
      );

      // NOTE: "does not evict when finalize fails" and "does not evict when
      // publish fails (clearPendingCommit path)" were removed (Dark Matter
      // DM-4b) — both tested the deleted receiver-side auto-commit
      // publish/finalize/clear cycle (see the "Receiver-side auto-commit
      // (Fix #1) — REMOVED" note above). Eviction is now gated purely on
      // whether the engine's decrypt result reports a roster-changing kind
      // (`joined` / `groupUpdate` / `invalidated`); there is no publish or
      // finalize step in the decrypt-triggered path left to fail.

      test('retries on next fetch when getMembers fails transiently', () async {
        // Review-driven (security-reviewer MEDIUM): if getMembers throws
        // right after a roster-changing decrypt result, the departed member
        // has already left the engine's roster but remains in the
        // in-memory cache AND the persistent store. Without a retry, the
        // stale pin lingers until the next message-triggered cycle (which
        // may never come for a silently-departed peer) or the 30-min
        // grace-window eviction (memory only, not persistent). The
        // service must queue the eviction and retry on the next fetch.
        final (:svc, :circle, :relay) = await buildSeededService();
        expect(svc.debugCachedLocationCount, 2);

        // Phase 2: deliver the group-changing event that removes bob.
        // getMembers throws once (transient FFI error).
        relay.replaceAll([
          '{"id":"proposal","kind":445,"content":"bob-remove"}',
        ]);
        circle
          ..decryptLocationResults = [
            fakeDecrypt(groupUpdated: true, mlsGroupId: const [10, 20, 30, 40]),
          ]
          ..getMembersThrowCount = 1;

        await svc.fetchMemberLocations(circle: evictionCircle);

        // Cache must be untouched — we could not determine the post-change
        // roster, so pruning would be unsafe.
        expect(
          svc.debugCachedLocationCount,
          2,
          reason: 'getMembers threw — eviction deferred, cache intact',
        );
        // No persistent prune yet — retry is queued.
        expect(
          circle.methodCalls,
          isNot(contains('removeLastKnownMember')),
          reason: 'persistent prune deferred until the retry succeeds',
        );

        // Phase 3: next fetch — no new relay messages, but the deferred
        // retry fires at entry. This time getMembers returns only alice,
        // and bob is evicted from both caches.
        relay.replaceAll(const []);
        circle
          ..resetResultIndices()
          ..decryptLocationResults = const []
          ..getMembersResults = [
            [
              TestCircleFactory.createMember(
                pubkey: 'alicepubkey',
                displayName: 'Alice',
              ),
            ],
          ];

        final getMembersCallsBefore = circle.methodCalls
            .where((c) => c == 'getMembers')
            .length;

        await svc.fetchMemberLocations(circle: evictionCircle);

        final getMembersCallsAfter = circle.methodCalls
            .where((c) => c == 'getMembers')
            .length;
        expect(
          getMembersCallsAfter - getMembersCallsBefore,
          greaterThanOrEqualTo(1),
          reason: 'deferred retry must call getMembers on the next fetch',
        );

        // Bob is gone from the in-memory cache.
        expect(
          svc.debugCachedLocationCount,
          1,
          reason: "bob evicted on retry — only alice's pin remains",
        );

        // Bob is gone from the persistent store.
        final bobRowsAfter = circle.lastKnownRows
            .where((r) => r['senderPubkey'] == 'bobpubkey')
            .toList();
        expect(
          bobRowsAfter,
          isEmpty,
          reason: "bob's persistent row must be pruned on retry",
        );
        expect(
          circle.methodCalls,
          contains('removeLastKnownMember'),
          reason: 'persistent prune runs when the deferred retry succeeds',
        );
      });

      test(
        'evicts departed member via _runEvolutionPoll (backgrounded path)',
        () async {
          // Review-driven (expert-panel + security-reviewer): the
          // evolution poller runs on app resume and is the primary
          // channel for processing leave commits received while the app
          // was backgrounded. Without eviction symmetry with
          // fetchMemberLocations, a departed member's stale pin would
          // linger after resume until a later location-fetch cycle.
          final (:svc, :circle, :relay) = await buildSeededService();
          expect(svc.debugCachedLocationCount, 2);

          // Deliver bob's removal via the evolution-poll path (no
          // location-fetch in between). The engine has already applied the
          // change by the time decrypt returns, so getMembers reflects the
          // post-change roster (only alice).
          relay.replaceAll([
            '{"id":"proposal-poll","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              fakeDecrypt(
                groupUpdated: true,
                mlsGroupId: const [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
              ],
            ];

          await svc.pollEvolutionEvents(circles: [evictionCircle]);

          // In-memory eviction.
          expect(
            svc.debugCachedLocationCount,
            1,
            reason: 'evolution-poll path must evict bob from cache on resume',
          );
          // Persistent prune.
          final bobRowsAfter = circle.lastKnownRows
              .where((r) => r['senderPubkey'] == 'bobpubkey')
              .toList();
          expect(
            bobRowsAfter,
            isEmpty,
            reason: "evolution-poll path must prune bob's persistent row",
          );
          expect(circle.methodCalls, contains('getMembers'));
          expect(circle.methodCalls, contains('removeLastKnownMember'));
        },
      );
    });

    group('clock-ahead peer', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        members: [
          TestCircleFactory.createMember(
            pubkey: 'sender1',
            displayName: 'Alice',
          ),
        ],
      );

      DecryptedLocation peerFix({
        required DateTime timestamp,
        required double latitude,
        DateTime? receivedAt,
      }) => DecryptedLocation(
        senderPubkey: 'sender1',
        latitude: latitude,
        longitude: -122,
        geohash: '9q8',
        timestamp: timestamp,
        expiresAt: timestamp.add(const Duration(minutes: 4)),
        receivedAt: receivedAt,
      );

      /// Writes [fix] into the mock's persistent store as the row a previous
      /// session left behind, stamped with the receipt instant [at].
      Future<void> seedStore(
        MockCircleService circle,
        DecryptedLocation fix, {
        required DateTime at,
      }) => circle.upsertLastKnownLocation(
        nostrGroupId: testCircle.nostrGroupId,
        senderPubkey: fix.senderPubkey,
        latitude: fix.latitude,
        longitude: fix.longitude,
        geohash: fix.geohash,
        timestamp: fix.timestamp,
        expiresAt: fix.expiresAt,
        purgeAfter: fix.timestamp.add(const Duration(days: 1)),
        updatedAt: at,
      );

      test('a wiped service writes no peer coordinate to its store', () async {
        // Its store is the deleted identity's: in production the circle
        // service is latched, but nothing here may rely on that.
        final store = MockCircleService();
        final wiped = LocationSharingService(
          circleService: store,
          relayService: MockRelayService(),
        );
        await wiped.wipeAll();
        await wiped.ingestStreamedLocation(
          circle: testCircle,
          decrypted: peerFix(
            timestamp: DateTime.utc(2026, 10, 16),
            latitude: 1,
          ),
        );
        expect(
          store.methodCalls,
          isNot(contains('upsertLastKnownLocation')),
          reason: "a coordinate of the deleted identity's peer was persisted",
        );
      });

      test('a wiped service takes no clock evidence from a location',
          () async {
        // A handler of the deleted identity's session can still reach the
        // wiped instance; the detector is reset at the logout's end and must
        // not be refilled behind it.
        final start = DateTime.utc(2026, 10, 15, 12);
        final detector = ClockSkewDetector(now: () => start);
        addTearDown(detector.dispose);
        LocationSharingService service() => LocationSharingService(
          circleService: MockCircleService(),
          relayService: MockRelayService(),
          clockSkewDetector: detector,
          now: () => start,
        );
        final fix = peerFix(
          timestamp: start.add(const Duration(minutes: 10)),
          latitude: 1,
        );
        final wiped = service();
        await wiped.wipeAll();
        await wiped.ingestStreamedLocation(circle: testCircle, decrypted: fix);
        expect(
          detector.trackedSourceCountForTest,
          0,
          reason: 'a peer of the deleted identity refilled the detector',
        );

        await service().ingestStreamedLocation(
          circle: testCircle,
          decrypted: fix,
        );
        expect(
          detector.trackedSourceCountForTest,
          1,
          reason: 'anti-vacuity: an open service records the sample',
        );
      });

      test(
        "a future-dated fix does not pin the peer's marker: the next honest "
        'fix replaces it',
        () async {
          final start = DateTime.utc(2026, 9, 21, 12);
          var clock = start;
          final circle = MockCircleService();
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => clock,
          );

          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(
              timestamp: start.add(const Duration(hours: 1)),
              latitude: 1,
            ),
          );
          final pinned = await svc.cachedLocations(testCircle);
          expect(pinned.single.latitude, 1.0);
          expect(
            pinned.single.timestamp,
            start.add(const Duration(hours: 1)),
            reason: 'the peer reading reaches the model unclamped — clamping '
                "it would discard an honest skewed peer's own data",
          );

          clock = start.add(const Duration(seconds: 10));
          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(timestamp: clock, latitude: 2),
          );

          final after = await svc.cachedLocations(testCircle);
          expect(
            after.single.latitude,
            2.0,
            reason: 'ranking on the sender reading alone leaves the marker at '
                'the future-dated fix for a whole hour',
          );
        },
      );

      test(
        'a replayed older fix still loses to a fresher cached one',
        () async {
          final start = DateTime.utc(2026, 9, 21, 12);
          var clock = start;
          final circle = MockCircleService();
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => clock,
          );

          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(timestamp: start, latitude: 3),
          );

          // The commit-gap replay hands back a genuinely old fix minutes later.
          clock = start.add(const Duration(minutes: 5));
          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(
              timestamp: start.subtract(const Duration(minutes: 20)),
              latitude: 4,
            ),
          );

          final after = await svc.cachedLocations(testCircle);
          expect(
            after.single.latitude,
            3.0,
            reason: 'ranking by arrival alone would overwrite the live fix '
                'with a 20-minute-old replayed one',
          );
          expect(
            circle.lastKnownRows.single['latitude'],
            3.0,
            reason: 'and the STORE must refuse the same write, or the two '
                'layers hold different fixes until the next hydration',
          );
        },
      );

      test(
        'the store is given the same receipt instant the cache ranks by',
        () async {
          // Two different notions of "now" would let the cache and the store
          // pick different freshest fixes, so a restart would move the marker.
          // The clock deliberately carries milliseconds the store's
          // Unix-seconds column cannot hold: without dropping them here the
          // two layers agree only to the second.
          final start = DateTime.utc(2026, 9, 21, 12);
          final circle = MockCircleService();
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => start.add(const Duration(milliseconds: 750)),
          );

          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(
              timestamp: start.add(const Duration(hours: 1)),
              latitude: 5,
            ),
          );

          final cached = await svc.cachedLocations(testCircle);
          expect(circle.lastKnownRows.single['updatedAt'], start);
          expect(cached.single.receivedAt, start);
          expect(
            cached.single.receivedAt,
            circle.lastKnownRows.single['updatedAt'],
            reason: 'the value, not just the second — the store persists Unix '
                'seconds and cannot keep anything finer',
          );
        },
      );

      test(
        'a rehydrated future-dated row is replaced by the next fix',
        () async {
          // The store keeps the peer reading verbatim, so the pin survives a
          // restart unless hydration bounds the row's rank too.
          final start = DateTime.utc(2026, 9, 21, 12);
          var clock = start;
          final circle = MockCircleService()
            ..snapshotLastKnownRows = [
              peerFix(
                timestamp: start.add(const Duration(hours: 1)),
                latitude: 6,
                receivedAt: start,
              ),
            ];
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => clock,
          );

          expect((await svc.cachedLocations(testCircle)).single.latitude, 6.0);

          clock = start.add(const Duration(seconds: 10));
          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(timestamp: clock, latitude: 7),
          );

          expect(
            (await svc.cachedLocations(testCircle)).single.latitude,
            7.0,
            reason: 'a hydrated row that ranks on its future reading pins the '
                'marker again on every restart',
          );
        },
      );

      test(
        'hydration keeps the rank the STORE gave the row, so the two layers '
        'accept the same fix',
        () async {
          // Re-stamping a rehydrated row with "now" ranks a future-dated one
          // ABOVE the rank the store holds it at, and every fix landing in
          // between is then accepted by the store and rejected by the cache —
          // so the NEXT resume's hydration jumps the marker to it. Every
          // resume re-hydrates (onAppPaused clears `_hydratedCircles`) and the
          // first fetch after one reaches ≥60 s back, so the window is
          // ordinary, not exotic.
          final wrote = DateTime.utc(2026, 9, 21, 12);
          final resume = wrote.add(const Duration(minutes: 30));
          final pinned = peerFix(
            timestamp: wrote.add(const Duration(hours: 1)),
            latitude: 6,
            receivedAt: wrote,
          );

          final circle = MockCircleService();
          await seedStore(circle, pinned, at: wrote);
          circle.snapshotLastKnownRows = [pinned];

          var clock = resume;
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => clock,
          );
          expect(
            (await svc.cachedLocations(testCircle)).single.latitude,
            6.0,
            reason: 'anti-vacuity: the pinned row really is what hydrated',
          );

          // Captured after the pinned fix ARRIVED but before this resume —
          // exactly the window the re-stamp would have hidden.
          clock = resume.add(const Duration(seconds: 1));
          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(
              timestamp: wrote.add(const Duration(minutes: 10)),
              latitude: 9,
            ),
          );

          final cached = (await svc.cachedLocations(testCircle)).single;
          final stored = circle.lastKnownRows.single;
          expect(
            cached.latitude,
            stored['latitude'],
            reason: 'the cache and the store must survive on the same fix, or '
                'the next hydration moves the marker to one of them',
          );
          expect(cached.latitude, 9.0);
        },
      );

      test(
        'a live-sync fix already in the cache is not overwritten by an older '
        'store row',
        () async {
          // Live-sync writes the cache before anything hydrates it, so the
          // store row the first hydration returns is not automatically the
          // fresher of the two.
          final start = DateTime.utc(2026, 9, 21, 12);
          final circle = MockCircleService()
            ..snapshotLastKnownRows = [
              peerFix(
                timestamp: start.subtract(const Duration(minutes: 20)),
                latitude: 2,
                receivedAt: start.subtract(const Duration(minutes: 20)),
              ),
            ];
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => start,
          );

          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(timestamp: start, latitude: 4),
          );

          expect(
            (await svc.cachedLocations(testCircle)).single.latitude,
            4.0,
            reason: 'a blind assign at hydration drops the fresher live fix',
          );
        },
      );

      test(
        'hydrating a stale future-dated snapshot over a live fix keeps the '
        "store's own verdict",
        () async {
          // The hydration comparison is between two ALREADY-RANKED rows, so it
          // uses the recorded ranks. Asking the ARRIVAL question here instead
          // would raise the stale row's ceiling to the live fix's later
          // receipt, tie, and hand the tie-break to the inflated reading — the
          // pin, straight back, on a snapshot that merely predates the ingest.
          final start = DateTime.utc(2026, 9, 21, 12);
          final pinned = peerFix(
            timestamp: start.add(const Duration(hours: 1)),
            latitude: 6,
            receivedAt: start,
          );

          final circle = MockCircleService();
          await seedStore(circle, pinned, at: start);
          // Set, but never hydrated before the ingest: this models the
          // snapshot that was already in flight when the live fix landed.
          circle.snapshotLastKnownRows = [pinned];

          var clock = start;
          final svc = LocationSharingService(
            circleService: circle,
            relayService: MockRelayService(),
            now: () => clock,
          );

          clock = start.add(const Duration(seconds: 10));
          await svc.ingestStreamedLocation(
            circle: testCircle,
            decrypted: peerFix(timestamp: clock, latitude: 7),
          );
          expect(
            circle.lastKnownRows.single['latitude'],
            7.0,
            reason: 'anti-vacuity: the STORE took the live fix, so the stale '
                'snapshot really is the losing row',
          );

          final cached = (await svc.cachedLocations(testCircle)).single;
          expect(cached.latitude, 7.0);
          expect(
            cached.latitude,
            circle.lastKnownRows.single['latitude'],
            reason: 'hydration must reach the verdict the store already did',
          );
        },
      );
    });

    group('onAppPaused', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        members: [
          TestCircleFactory.createMember(
            pubkey: 'sender1',
            displayName: 'Alice',
          ),
        ],
      );

      test(
        'clears in-memory caches without touching the persistent store',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"loc"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);
          expect(svc.debugCachedLocationCount, 1);
          expect(svc.debugSeenEventIdsCount, 1);
          // Upsert reached the "persistent store".
          expect(mockCircle.lastKnownRows, hasLength(1));

          svc.onAppPaused();

          expect(svc.debugCachedLocationCount, 0);
          expect(svc.debugSeenEventIdsCount, 0);
          // wipeAllLastKnownLocations / removeLastKnownCircle must NOT have
          // been called — the persistent store stays intact.
          expect(
            mockCircle.methodCalls,
            isNot(contains('wipeAllLastKnownLocations')),
          );
          expect(
            mockCircle.methodCalls,
            isNot(contains('removeLastKnownCircle')),
          );
          expect(mockCircle.lastKnownRows, hasLength(1));
        },
      );

      test('also clears the process-wide log-alias memo', () async {
        // The memo is a top-level module cache in log_alias.dart, not owned
        // by any one LocationSharingService instance — this proves the
        // service's pause hook still reaches it.
        final originalFfiCall = logAliasFfiCall;
        addTearDown(() {
          logAliasFfiCall = originalFfiCall;
          clearLogAliasMemo();
        });
        var calls = 0;
        logAliasFfiCall = ({required class_, required value}) {
          calls++;
          return '${class_.name}#fake$calls';
        };
        clearLogAliasMemo();

        logAliasHandle(LogAliasClass.circle, 'deadbeef');
        expect(calls, 1);
        logAliasHandle(LogAliasClass.circle, 'deadbeef');
        expect(calls, 1, reason: 'memo hit before pause');

        LocationSharingService(
          circleService: MockCircleService(),
          relayService: MockRelayService(),
        ).onAppPaused();

        logAliasHandle(LogAliasClass.circle, 'deadbeef');
        expect(
          calls,
          2,
          reason: 'onAppPaused must drop the log-alias memo too, or a '
              'handle minted before backgrounding keeps answering for the '
              'rest of the process',
        );
      });

      test(
        'rehydrates from the persistent store on the first fetch after the '
        'resume, and not while paused',
        () async {
          final hydratedLoc = DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 41,
            longitude: -74,
            geohash: 'dr5r',
            timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          );

          // After pause, the next fetch should hit snapshotLastKnownForCircle
          // again (since _hydratedCircles was cleared) and surface the row.
          final mockRelay = MockRelayService();
          final mockCircle = MockCircleService()
            ..snapshotLastKnownRows = [hydratedLoc];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          int snapshotCalls() => mockCircle.methodCalls
              .where((c) => c == 'snapshotLastKnownForCircle')
              .length;

          // First fetch hydrates.
          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, hasLength(1));
          expect(first.locations.first.latitude, 41.0);

          // Hydration is ONCE PER CIRCLE PER SESSION, and the reads that keep
          // the map alive between polls must not re-run it. Without these
          // intervening reads the count below is 2 whether or not the pause
          // reset anything, i.e. the test would pass while proving nothing:
          // it is the 1 here that makes the 2 afterwards evidence.
          for (var i = 0; i < 4; i++) {
            await svc.cachedLocations(testCircle);
          }
          expect(
            snapshotCalls(),
            1,
            reason: 'a merge-from-store on every read would also undo the '
                'stale-eviction and departed-member bounds the two guards '
                'below pin',
          );

          svc.onAppPaused();
          expect(svc.debugCachedLocationCount, 0);

          // While the app is away nothing goes back in: a read hydrates
          // nothing, and does not even ask the store.
          expect(await svc.cachedLocations(testCircle), isEmpty);
          expect(svc.debugCachedLocationCount, 0);
          expect(
            snapshotCalls(),
            1,
            reason: 'every last-known row was read back into a paused '
                'process',
          );

          // The resume opens it; the next fetch rehydrates from the store.
          svc.onAppResumed();
          final second = await svc.fetchMemberLocations(circle: testCircle);
          expect(second.locations, hasLength(1));
          expect(second.locations.first.latitude, 41.0);

          // snapshotLastKnownForCircle called twice — once per session —
          // proving _hydratedCircles was genuinely reset by onAppPaused.
          expect(snapshotCalls(), 2);
        },
      );

      test(
        'an entry past the eviction grace stays evicted, even though the '
        'store still holds it',
        () async {
          // The store keeps a row to `purge_after` (24 h); the in-memory cache
          // drops it at `expiresAt + cacheEvictionGrace`. That bound on how
          // much plaintext location a long-running session accumulates only
          // holds while hydration is once-per-session — a merge on every read
          // would put the row straight back.
          final now = DateTime.utc(2026, 9, 20, 12);
          final stale = DecryptedLocation(
            senderPubkey: 'sender-stale',
            latitude: 41,
            longitude: -74,
            geohash: 'dr5r',
            timestamp: now.subtract(const Duration(hours: 3)),
            expiresAt: now.subtract(const Duration(hours: 2)),
          );
          final mockCircle = MockCircleService()
            ..snapshotLastKnownRows = [stale];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: MockRelayService(),
            now: () => now,
          );

          expect(await svc.cachedLocations(testCircle), isEmpty);
          expect(
            mockCircle.snapshotLastKnownRows,
            hasLength(1),
            reason: 'anti-vacuity: the STORE still has the row, so the empty '
                'read above is eviction rather than an empty store',
          );
          expect(
            await svc.cachedLocations(testCircle),
            isEmpty,
            reason: 'a second read must not resurrect it either',
          );
        },
      );

      test(
        'a departed member whose store row could not be deleted does not come '
        'back on the next read',
        () async {
          // `_evictDepartedMembers` prunes cache AND store, but the store half
          // is best-effort. The in-memory eviction is what bounds the visible
          // window when the disk delete fails — and it only bounds anything
          // while the cache is not re-merged from that undeleted row.
          final departed = DecryptedLocation(
            senderPubkey: 'sender-departed',
            latitude: 41,
            longitude: -74,
            geohash: 'dr5r',
            timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          );
          final mockCircle = MockCircleService()
            ..snapshotLastKnownRows = [departed]
            ..shouldThrowOnRemoveLastKnownMember = true
            // The post-commit roster no longer has the sender.
            ..getMembersResults = [const []]
            ..decryptLocationResults = [
              fakeDecrypt(groupUpdated: true),
            ];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: MockRelayService(
              groupMessages: const [
                '{"id":"evtLeave","kind":445,"content":"x"}',
              ],
            ),
          );
          // A member when the row was stored and when the circle was read;
          // the commit this fetch applies removes them.
          final beforeRemoval = TestCircleFactory.createCircle(
            displayName: 'Test',
            members: [
              TestCircleFactory.createMember(
                pubkey: 'sender1',
                displayName: 'Alice',
              ),
              TestCircleFactory.createMember(
                pubkey: 'sender-departed',
                displayName: 'Dee',
              ),
            ],
          );

          final fetched = await svc.fetchMemberLocations(circle: beforeRemoval);
          expect(fetched.groupUpdated, isTrue);
          expect(
            mockCircle.removeLastKnownMemberCalls.map((c) => c.senderPubkey),
            ['sender-departed'],
            reason: 'anti-vacuity: the store delete really was attempted, and '
                'really did throw',
          );
          expect(
            await svc.cachedLocations(beforeRemoval),
            isEmpty,
            reason: "a removed member's pin must not return from the row the "
                'failed delete left behind (Security Rule 10)',
          );
        },
      );

      test(
        "hydration never shows a row whose sender is no longer in the circle",
        () async {
          // A removal a background cycle applied leaves the departed member's
          // last row in the store with no foreground reconcile behind it.
          final mockCircle = MockCircleService()
            ..snapshotLastKnownRows = [
              DecryptedLocation(
                senderPubkey: 'sender-departed',
                latitude: 41,
                longitude: -74,
                geohash: 'dr5r',
                timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
              ),
              DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(minutes: 1)),
                expiresAt: DateTime.now().add(const Duration(hours: 1)),
              ),
            ];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: MockRelayService(),
          );

          final shown = await svc.cachedLocations(testCircle);

          expect(
            shown.map((location) => location.pubkey),
            ['sender1'],
            reason: 'a current member hydrates; a departed one never does',
          );
        },
      );

      test('is safe to call repeatedly and before any fetch', () {
        final svc = LocationSharingService(
          circleService: MockCircleService(),
          relayService: MockRelayService(),
        );
        expect(svc.onAppPaused, returnsNormally);
        svc
          ..onAppPaused()
          ..onAppPaused();
        expect(svc.debugCachedLocationCount, 0);
        expect(svc.debugSeenEventIdsCount, 0);
      });

      test(
        'aborts a fetch that was paused mid-await without repopulating caches',
        () async {
          // Review-driven (security-reviewer MEDIUM #M1): if `pause`
          // lands between the relay fetch and the decrypt loop, the
          // continuing fetch must NOT refill the caches that pause
          // just cleared.
          //
          // The slow relay races the pause — we `await` the fetch
          // result, the relay completes, and before the mock runs its
          // decrypt loop we invoke `onAppPaused` via a microtask that
          // fires between `fetchGroupMessages` and the processing
          // loop. The pause-generation fence must abort the fetch.
          final slowRelay = _PauseRacingRelayService(
            messages: [
              '{"id":"evt1","kind":445,"content":"a"}',
              '{"id":"evt2","kind":445,"content":"b"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender2',
                  latitude: 38,
                  longitude: -121,
                  geohash: '9q9',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: slowRelay,
          );
          slowRelay.onFetchCalled = svc.onAppPaused;

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(
            result.locations,
            isEmpty,
            reason: 'paused fetch must return empty result',
          );
          expect(
            svc.debugCachedLocationCount,
            0,
            reason: 'cache must remain empty — no post-pause repopulation',
          );
          // The fence fires AFTER the relay await but BEFORE the
          // decrypt loop, so no decryptLocation calls should appear.
          expect(
            mockCircle.methodCalls.where((c) => c == 'decryptLocation'),
            isEmpty,
          );
        },
      );

      test(
        'retains _lastFetchTime across pause (incremental resume)',
        () async {
          // Review-driven (test-writer N3): a regression that clears
          // _lastFetchTime on pause would silently reset the `since`
          // cursor, causing the first post-resume fetch to pull full
          // history. Capture the `since` on a post-pause fetch and
          // assert it matches the pre-pause fetch time.
          final capturingRelay = _SinceCapturingRelayService();
          final mockCircle = MockCircleService()
            ..decryptLocationResults = const [];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: capturingRelay,
          );

          final before = DateTime.now();
          await svc.fetchMemberLocations(circle: testCircle);
          // First fetch: `since` is null (no prior fetch).
          expect(capturingRelay.lastSince, isNull);

          svc.onAppPaused();

          await svc.fetchMemberLocations(circle: testCircle);
          // Post-pause fetch: since must be non-null and within a
          // narrow window of the first fetch time. The service applies
          // a 60s clock-skew buffer, so we allow for it here.
          expect(capturingRelay.lastSince, isNotNull);
          final delta = before.difference(capturingRelay.lastSince!).inSeconds;
          expect(
            delta,
            inInclusiveRange(0, 75),
            reason: '`since` ≈ first fetch time minus clock-skew buffer',
          );
        },
      );
    });

    group('removeCircle', () {
      // Uses a distinct nostrGroupId so the test asserts cleanup of the
      // evolution-poll cursor independent of any other group's state.
      final removableCircle = TestCircleFactory.createCircle(
        mlsGroupId: const [0x99, 0x88, 0x77, 0x66],
        nostrGroupId: const [0x11, 0x22, 0x33, 0x44],
        displayName: 'Removable',
        members: [
          TestCircleFactory.createMember(pubkey: 'self', isAdmin: true),
        ],
      );

      test('clears the evolution-poll cursor so the next poll re-queries '
          'without a stale `since`', () async {
        // Review-driven (flutter-reviewer BLOCKER): a regression that
        // leaves `_lastEvolutionFetchTime[circleKey]` populated after
        // the circle is deleted would cause a freshly re-created group
        // sharing the same nostr_group_id to skip events that landed
        // between the cursor and the rejoin.
        final capturingRelay = _SinceCapturingRelayService();
        final mockCircle = MockCircleService();

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: capturingRelay,
        );

        // First poll — seeds _lastEvolutionFetchTime for this circle.
        await svc.pollEvolutionEvents(circles: [removableCircle]);

        // Second poll — `since` must now be non-null (cursor seeded).
        await svc.pollEvolutionEvents(circles: [removableCircle]);
        expect(
          capturingRelay.lastSince,
          isNotNull,
          reason: 'second poll should use the cursor from the first as `since`',
        );

        // Deletion must clear the cursor.
        await svc.removeCircle(
          mlsGroupId: removableCircle.mlsGroupId,
          nostrGroupId: removableCircle.nostrGroupId,
        );

        // Post-delete poll — `since` must be null again.
        await svc.pollEvolutionEvents(circles: [removableCircle]);
        expect(
          capturingRelay.lastSince,
          isNull,
          reason:
              'removeCircle must clear `_lastEvolutionFetchTime` so the '
              'next poll fetches from the beginning rather than from a '
              'cursor rooted in the deleted-circle era',
        );
      });
    });

    // X6: a circle's routing id moves when its routing rotates, its MLS
    // group id does not.
    group('a circle whose routing id rotates', () {
      Circle routedAs(List<int> nostrGroupId) =>
          TestCircleFactory.createCircle(
            nostrGroupId: nostrGroupId,
            members: [
              TestCircleFactory.createMember(pubkey: 'sender1', isAdmin: true),
            ],
          );
      final before = routedAs(const [0x11, 0x22]);
      final after = routedAs(const [0x33, 0x44]);

      Future<(LocationSharingService, MockRelayService)> seeded() async {
        final relay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final svc = LocationSharingService(
          circleService: MockCircleService()
            ..decryptLocationResults = [
              fakeDecrypt(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 1,
                  longitude: 2,
                  geohash: 's00',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ],
          relayService: relay,
        );
        await svc.fetchMemberLocations(circle: before);
        await svc.pollEvolutionEvents(circles: [before]);
        return (svc, relay);
      }

      test('keeps its cached locations, and polls the new id from no floor',
          () async {
        final (svc, relay) = await seeded();
        expect(await svc.cachedLocations(after), hasLength(1));

        await svc.fetchMemberLocations(circle: after);
        await svc.pollEvolutionEvents(circles: [after]);
        expect(
          relay.groupMessageSinces.skip(2),
          [null, null],
          reason: 'a floor taken under the prior id says nothing about what '
              'the new id carries',
        );

        await svc.fetchMemberLocations(circle: after);
        expect(
          relay.groupMessageSinces.last,
          isNotNull,
          reason: 'the new id keeps a floor of its own',
        );
      });

      test('leaves nothing behind under either id once removed', () async {
        final (svc, relay) = await seeded();
        await svc.fetchMemberLocations(circle: after);

        await svc.removeCircle(
          mlsGroupId: after.mlsGroupId,
          nostrGroupId: after.nostrGroupId,
        );

        expect(svc.debugCachedLocationCount, 0);
        await svc.fetchMemberLocations(circle: before);
        expect(relay.groupMessageSinces.last, isNull);
      });
    });

    group('constructor', () {
      test('asserts maxSeenEventIds is positive', () {
        expect(
          () => LocationSharingService(
            circleService: MockCircleService(),
            relayService: MockRelayService(),
            maxSeenEventIds: 0,
          ),
          throwsA(isA<AssertionError>()),
        );
      });

      test('asserts cacheEvictionGrace is non-negative', () {
        expect(
          () => LocationSharingService(
            circleService: MockCircleService(),
            relayService: MockRelayService(),
            cacheEvictionGrace: const Duration(seconds: -1),
          ),
          throwsA(isA<AssertionError>()),
        );
      });
    });
  });
}

/// A service that throws on the first decrypt call but succeeds on the second.
class _ThrowOnFirstDecryptService
    with CircleServiceRetentionStubs
    implements CircleService {
  int _decryptCount = 0;

  List<LocationEventResult> _decryptOrThrow() {
    _decryptCount++;
    if (_decryptCount == 1) {
      throw const CircleServiceException('MLS decryption failed');
    }
    return [
      LocationEventResult(
        kind: LocationEventKind.location,
        location: DecryptedLocation(
          senderPubkey: 'sender1',
          latitude: 38,
          longitude: -121,
          geohash: '9q9',
          timestamp: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 23)),
        ),
        // `testCircle`'s default `mlsGroupId` — both call sites below decrypt
        // against a `testCircle` ambient. `mlsGroupId` is never empty in
        // production (Rust's `convert_location_result` sets it on every
        // variant).
        mlsGroupId: const [1, 2, 3, 4],
        epoch: 0,
      ),
    ];
  }

  @override
  Future<IngestResult> ingestEvent({required String eventJson}) async =>
      IngestResult(results: _decryptOrThrow(), held: false);

  @override
  Future<LocationSeal> sealLocation({
    required List<int> mlsGroupId,
    required double latitude,
    required double longitude,
  }) async => throw UnimplementedError();

  @override
  Future<LocationPublishFfi> publishSealedLocation(LocationSealed seal) async =>
      throw UnimplementedError();

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
  }) async => throw UnimplementedError();

  @override
  Future<List<Circle>> getVisibleCircles() async => [];

  @override
  Future<Circle?> getCircle(List<int> mlsGroupId) async => null;

  @override
  Future<List<CircleMember>> getMembers(List<int> mlsGroupId) async => [];

  @override
  Future<List<Invitation>> getPendingInvitations() async => [];

  @override
  Future<Circle> acceptInvitation(List<int> mlsGroupId) async =>
      throw UnimplementedError();

  @override
  Future<void> declineInvitation(List<int> mlsGroupId) async {}

  @override
  Future<LeaveDelivery> leaveCircle({required List<int> mlsGroupId}) async =>
      LeaveDelivery.left;

  @override
  Future<ChangeDelivery> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async => ChangeDelivery.applied;

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();
}

/// A mock relay service that allows adding messages between fetches.
class _MutableMockRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => const SubscriptionHealthResult.empty();

  _MutableMockRelayService({List<String>? initialMessages})
    : _messages = initialMessages ?? [];

  final List<String> _messages;

  /// Adds a new message to be returned on the next fetch.
  void addMessage(String eventJson) => _messages.add(eventJson);

  /// Replaces the pending message list. Used by tests that need to
  /// simulate a new batch arriving on a later fetch cycle.
  void replaceAll(List<String> newMessages) {
    _messages
      ..clear()
      ..addAll(newMessages);
  }

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async => List.of(_messages);

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async => PublishResult(
    eventId: 'mock',
    acceptedBy: relays,
    rejectedBy: const [],
    failed: const [],
  );

  // A receive-plane stub: nothing here publishes a location, so reaching the
  // one-shot ladder from one of these tests is a routing bug, not a fixture
  // gap.
  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// A relay service that fires [onFetchCalled] inside `fetchGroupMessages`
/// so tests can simulate `onAppPaused` landing between the relay round-trip
/// and the service's post-fetch processing loop.
///
/// Dart is single-threaded, so invoking the callback synchronously before
/// returning the message list guarantees the pause-generation counter is
/// incremented before the `await` in `fetchMemberLocations` resumes — the
/// fence check that immediately follows the relay await will then observe
/// the mismatch and abort.
class _PauseRacingRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => const SubscriptionHealthResult.empty();

  _PauseRacingRelayService({required this.messages});

  final List<String> messages;

  /// Invoked once, inside [fetchGroupMessages], right before the relay
  /// returns its message batch. Tests wire this to `svc.onAppPaused` so
  /// the pause appears to land mid-await.
  void Function()? onFetchCalled;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    onFetchCalled?.call();
    return List.of(messages);
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async => PublishResult(
    eventId: 'mock',
    acceptedBy: relays,
    rejectedBy: const [],
    failed: const [],
  );

  // A receive-plane stub: nothing here publishes a location, so reaching the
  // one-shot ladder from one of these tests is a routing bug, not a fixture
  // gap.
  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}

/// A relay service that captures the `since` argument passed to every
/// `fetchGroupMessages` call. Used to assert that `_lastFetchTime` is
/// retained across `onAppPaused`, so the post-resume fetch issues an
/// incremental query rather than pulling full history.
class _SinceCapturingRelayService implements RelayService {
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.empty();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => const SubscriptionHealthResult.empty();


  /// The `since` captured from the most recent `fetchGroupMessages` call.
  DateTime? lastSince;

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    lastSince = since;
    return const [];
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async => PublishResult(
    eventId: 'mock',
    acceptedBy: relays,
    rejectedBy: const [],
    failed: const [],
  );

  // A receive-plane stub: nothing here publishes a location, so reaching the
  // one-shot ladder from one of these tests is a routing bug, not a fixture
  // gap.
  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async => [];

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async => RelayEventCheck(relayUrl: relayUrl, found: false, eventCount: 0);

  @override
  Future<void> disconnectRelay(String url) async {}
}
