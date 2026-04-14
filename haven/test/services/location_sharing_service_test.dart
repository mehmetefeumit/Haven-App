/// Tests for LocationSharingService and related data classes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';

import '../mocks/circle_service_retention_stubs.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

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
        precision: 'Enhanced',
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
        precision: 'Enhanced',
      );
      expect(loc.isExpired, isFalse);
    });

    test('freshness returns live for < 1 minute', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(seconds: 30)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.live);
    });

    test('freshness returns recent for 1-5 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 3)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.recent);
    });

    test('freshness returns stale for 5-15 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 10)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.stale);
    });

    test('freshness returns old for >= 15 minutes', () {
      final loc = MemberLocation(
        pubkey: 'abc123',
        latitude: 37.7749,
        longitude: -122.4194,
        geohash: '9q8yyk8',
        timestamp: DateTime.now().subtract(const Duration(minutes: 20)),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      );
      expect(loc.freshness, LocationFreshness.old);
    });
  });

  group('DecryptedLocation', () {
    test('isExpired works correctly', () {
      final expired = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37.0,
        longitude: -122.0,
        geohash: '9q8',
        timestamp: DateTime.now().subtract(const Duration(hours: 25)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        precision: 'Enhanced',
      );
      expect(expired.isExpired, isTrue);

      final valid = DecryptedLocation(
        senderPubkey: 'abc',
        latitude: 37.0,
        longitude: -122.0,
        geohash: '9q8',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
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
      test('calls encrypt then publish', () async {
        await service.publishLocation(
          mlsGroupId: [1, 2, 3],
          senderPubkeyHex: 'abc123',
          latitude: 37.7749,
          longitude: -122.4194,
          retentionSecs: 24 * 60 * 60,
        );

        expect(mockCircleService.methodCalls, contains('encryptLocation'));
        expect(mockRelayService.methodCalls, contains('publishEvent'));
        expect(mockRelayService.publishedEvents, hasLength(1));
      });
    });

    group('fetchMemberLocations', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        membershipStatus: MembershipStatus.accepted,
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

      test('fetches and decrypts locations', () async {
        // Set up mock relay to return event JSONs
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.7749,
              longitude: -122.4194,
              geohash: '9q8yyk8',
              timestamp: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 23)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          // First event is a group update (commit/proposal)
          const DecryptResult(groupUpdated: true),
          // Second event is a location
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 23)),
              precision: 'Enhanced',
            ),
          ),
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 23)),
              precision: 'Enhanced',
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(minutes: 40)),
                expiresAt: DateTime.now().subtract(const Duration(minutes: 10)),
                precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: now.subtract(const Duration(minutes: 5)),
              expiresAt: now.add(const Duration(hours: 23)),
              precision: 'Enhanced',
            ),
          ),
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 38.0,
              longitude: -121.0,
              geohash: '9q9',
              timestamp: now,
              expiresAt: now.add(const Duration(hours: 23)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.7749,
              longitude: -122.4194,
              geohash: '9q8yyk8',
              timestamp: DateTime.now(),
              expiresAt: DateTime.now().add(const Duration(hours: 23)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: now,
              expiresAt: now.add(const Duration(hours: 23)),
              precision: 'Enhanced',
            ),
          ),
          // Second decrypt result for the new event
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 38.0,
              longitude: -121.0,
              geohash: '9q9',
              timestamp: now.add(const Duration(minutes: 5)),
              expiresAt: now.add(const Duration(hours: 23)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: DateTime.now().subtract(const Duration(hours: 25)),
              expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
              precision: 'Enhanced',
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
        membershipStatus: MembershipStatus.accepted,
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: DateTime.now().subtract(const Duration(hours: 2)),
              expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = [
          DecryptResult(
            location: DecryptedLocation(
              senderPubkey: 'sender1',
              latitude: 37.0,
              longitude: -122.0,
              geohash: '9q8',
              timestamp: DateTime.now().subtract(const Duration(minutes: 35)),
              expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
              precision: 'Enhanced',
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
        final mockCircle = MockCircleService();
        // Return null decrypts — we're only exercising the dedup path.
        mockCircle.decryptLocationResults = List.filled(5, null);

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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = List.filled(5, null);

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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(minutes: 30)),
                // 500 ms inside the grace cutoff → retained under `<`,
                // would still be retained under a theoretical `<=`, but
                // a `<=` flip combined with re-reading `DateTime.now()`
                // in eviction would consistently evict; if we ever tune
                // the test, anything <=0 nudge is unstable.
                expiresAt: now.subtract(grace).add(boundaryNudge),
                precision: 'Enhanced',
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: DateTime.now().subtract(const Duration(seconds: 2)),
                expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
                precision: 'Enhanced',
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
            membershipStatus: MembershipStatus.accepted,
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
            membershipStatus: MembershipStatus.accepted,
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'senderB',
                latitude: 40.0,
                longitude: -100.0,
                geohash: '9yz',
                timestamp: now,
                expiresAt: now.add(const Duration(hours: 23)),
                precision: 'Enhanced',
              ),
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
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'senderA',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(hours: 2)),
                expiresAt: now.subtract(const Duration(hours: 1)),
                precision: 'Enhanced',
              ),
            ),
          ];
          mockRelay.replaceAll(['{"id":"evtA","kind":445,"content":"stale"}']);

          final fetchedA = await svc.fetchMemberLocations(circle: circleA);
          expect(
            fetchedA.locations,
            isEmpty,
            reason: 'A\'s past-grace entry must be evicted',
          );

          // B's cache must remain intact — fetching A must not touch B.
          expect(
            svc.debugCachedLocationCount,
            1,
            reason: 'only B\'s fresh entry should remain',
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
        final mockCircle = MockCircleService();
        mockCircle.decryptLocationResults = List.filled(4, null);

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
        mockCircle.decryptLocationResults = [null];
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
          // Isolate the `_seenEventIds.add` returning false branch:
          // feed the same 3 events twice, with cap >> batch. Second
          // pass must add zero to the decrypt count.
          final mockRelay = MockRelayService(
            groupMessages: const [
              '{"id":"e0","kind":445,"content":"c0"}',
              '{"id":"e1","kind":445,"content":"c1"}',
              '{"id":"e2","kind":445,"content":"c2"}',
            ],
          );
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = List.filled(3, null);

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
    });

    group('onAppPaused', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'Test',
        membershipStatus: MembershipStatus.accepted,
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
                precision: 'Enhanced',
                retentionSecs: 24 * 60 * 60,
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

      test(
        'rehydrates from the persistent store on the next fetch after pause',
        () async {
          final hydratedLoc = DecryptedLocation(
            senderPubkey: 'sender1',
            latitude: 41.0,
            longitude: -74.0,
            geohash: 'dr5r',
            timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
            precision: 'Standard',
            retentionSecs: 24 * 60 * 60,
          );

          // After pause, the next fetch should hit snapshotLastKnownForCircle
          // again (since _hydratedCircles was cleared) and surface the row.
          final mockRelay = MockRelayService(groupMessages: const []);
          final mockCircle = MockCircleService()
            ..snapshotLastKnownRows = [hydratedLoc];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          // First fetch hydrates.
          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, hasLength(1));
          expect(first.locations.first.isStale, isTrue);

          svc.onAppPaused();
          expect(svc.debugCachedLocationCount, 0);

          // Second fetch — should rehydrate from the persistent store.
          final second = await svc.fetchMemberLocations(circle: testCircle);
          expect(second.locations, hasLength(1));
          expect(second.locations.first.latitude, 41.0);
          expect(second.locations.first.isStale, isTrue);

          // snapshotLastKnownForCircle called twice — once per fetch — proving
          // _hydratedCircles was genuinely reset by onAppPaused.
          final snapshotCalls = mockCircle.methodCalls
              .where((c) => c == 'snapshotLastKnownForCircle')
              .length;
          expect(snapshotCalls, 2);
        },
      );

      test('is safe to call repeatedly and before any fetch', () {
        final svc = LocationSharingService(
          circleService: MockCircleService(),
          relayService: MockRelayService(),
        );
        expect(svc.onAppPaused, returnsNormally);
        svc.onAppPaused();
        svc.onAppPaused();
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37.0,
                longitude: -122.0,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
                precision: 'Enhanced',
              ),
            ),
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender2',
                latitude: 38.0,
                longitude: -121.0,
                geohash: '9q9',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
                precision: 'Enhanced',
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
          final mockCircle = MockCircleService();
          mockCircle.decryptLocationResults = const [];

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

  @override
  Future<DecryptResult?> decryptLocation({required String eventJson}) async {
    _decryptCount++;
    if (_decryptCount == 1) {
      throw const CircleServiceException('MLS decryption failed');
    }
    return DecryptResult(
      location: DecryptedLocation(
        senderPubkey: 'sender1',
        latitude: 38.0,
        longitude: -121.0,
        geohash: '9q9',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
        precision: 'Enhanced',
      ),
    );
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int retentionSecs,
    String? displayName,
    String? precisionLabel,
  }) async => throw UnimplementedError();

  @override
  Future<CircleCreationResult> createCircle({
    required List<int> identitySecretBytes,
    required List<KeyPackageData> memberKeyPackages,
    required String name,
    required CircleType circleType,
    String? description,
    List<String>? relays,
    List<String> creatorFallbackRelays = const [],
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
  Future<void> leaveCircle(List<int> mlsGroupId) async {}

  @override
  Future<Invitation> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async => throw UnimplementedError();

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signRelayListEvent({
    required List<int> identitySecretBytes,
    required List<String> relays,
  }) async => throw UnimplementedError();

  @override
  Future<String> signDeletionEvent({
    required List<int> identitySecretBytes,
    required List<String> eventIds,
  }) async => throw UnimplementedError();

  @override
  Future<List<List<int>>> groupsNeedingSelfUpdate(int thresholdSecs) async =>
      [];

  @override
  Future<void> selfUpdate(List<int> mlsGroupId) async {}
}

/// A mock relay service that allows adding messages between fetches.
class _MutableMockRelayService implements RelayService {
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

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async => throw UnimplementedError();

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
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

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async => throw UnimplementedError();

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
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
}

/// A relay service that captures the `since` argument passed to every
/// `fetchGroupMessages` call. Used to assert that `_lastFetchTime` is
/// retained across `onAppPaused`, so the post-resume fetch issues an
/// incremental query rather than pulling full history.
class _SinceCapturingRelayService implements RelayService {
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

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {}

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async => throw UnimplementedError();

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async => [];

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async => [];

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async => null;

  @override
  Future<List<String>> fetchGiftWraps({
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
}
