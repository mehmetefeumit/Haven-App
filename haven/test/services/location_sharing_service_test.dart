/// Tests for LocationSharingService and related data classes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/relay_service.dart';
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
      );
      expect(loc.isExpired, isFalse);
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
      test('calls encrypt then publish', () async {
        await service.publishLocation(
          mlsGroupId: [1, 2, 3],
          senderPubkeyHex: 'abc123',
          latitude: 37.7749,
          longitude: -122.4194,
        );

        expect(mockCircleService.methodCalls, contains('encryptLocation'));
        expect(mockRelayService.methodCalls, contains('publishEvent'));
        expect(mockRelayService.publishedEvents, hasLength(1));
      });

      test(
        'forwards kLocationPublishMaxInterval + buffer as updateIntervalSecs',
        () async {
          // Regression guard for the no-gap invariant. The service MUST
          // pass `publish_max + kTtlNetworkBufferSeconds` (168 + 30 =
          // 198s), NOT the nominal 120s or the per-tick jittered publish
          // interval. Rust samples the outer NIP-40 expiration tag in
          // `[interval, 2 * interval]`, so passing 198 yields a TTL
          // window `[198, 396]s` whose floor exceeds the maximum
          // jittered publish delay (168s) with a 30s network buffer.
          //
          // Why this matters: if this drifts back to 120s, the TTL
          // floor (120s) falls below the publish ceiling (168s),
          // reopening a 48s worst-case relay-residency gap in which
          // no valid event exists on the relay.
          await service.publishLocation(
            mlsGroupId: [1, 2, 3],
            senderPubkeyHex: 'abc123',
            latitude: 37.7749,
            longitude: -122.4194,
          );

          expect(
            mockCircleService.capturedUpdateIntervalSecs,
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          );
          expect(mockCircleService.capturedUpdateIntervalSecs, 198);
        },
      );
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

      test('fetches and decrypts locations', () async {
        // Set up mock relay to return event JSONs
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"encrypted"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            DecryptResult(
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
            const DecryptResult(groupUpdated: true),
            // Second event is a location
            DecryptResult(
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
            DecryptResult(
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
      // Group sync cursor (M2): advance only past fully-processed events.
      // ------------------------------------------------------------------
      DecryptResult locationResult(String sender) => DecryptResult(
        location: DecryptedLocation(
          senderPubkey: sender,
          latitude: 37,
          longitude: -122,
          geohash: '9q8',
          timestamp: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 23)),
        ),
      );

      test('advances group cursor to the newest fully-processed event', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
            '{"id":"evtB","kind":445,"created_at":1700000200,"content":"commit"}',
          ],
        );
        // Processed in ascending created_at order: evtA(100) then evtB(200).
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            locationResult('sender1'),
            const DecryptResult(groupUpdated: true),
          ];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        await svc.fetchMemberLocations(circle: testCircle);

        expect(mockCircle.advanceGroupCursorLastSecs, 1700000200);
      });

      test(
        'does not advance group cursor when every event is unprocessable',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtA","kind":445,"created_at":1700000100,"content":"x"}',
            ],
          );
          // Default MockCircleService returns null (unprocessable) for decrypts.
          final mockCircle = MockCircleService();
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.fetchMemberLocations(circle: testCircle);

          expect(mockCircle.advanceGroupCursorLastSecs, isNull);
        },
      );

      test('advances only to the newest SUCCESSFUL event, never past an '
          'unprocessable one', () async {
        final mockRelay = MockRelayService(
          groupMessages: [
            '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
            '{"id":"evtB","kind":445,"created_at":1700000200,"content":"unp"}',
          ],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            locationResult('sender1'), // evtA(100) succeeds
            null, // evtB(200) unprocessable
          ];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        await svc.fetchMemberLocations(circle: testCircle);

        // Must stop at the newest SUCCESS (100), not the newest event (200,
        // which stays eligible for retry).
        expect(mockCircle.advanceGroupCursorLastSecs, 1700000100);
      });

      // The evolution poller (_runEvolutionPoll) has its OWN cursor-advance
      // accumulator; the same contract must hold there.
      test(
        'evolution poller advances group cursor to newest processed event',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtA","kind":445,"created_at":1700000100,"content":"loc"}',
              '{"id":"evtB","kind":445,"created_at":1700000200,"content":"commit"}',
            ],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              locationResult('sender1'),
              const DecryptResult(groupUpdated: true),
            ];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.pollEvolutionEvents(circles: [testCircle]);

          expect(mockCircle.advanceGroupCursorLastSecs, 1700000200);
        },
      );

      test(
        'evolution poller does not advance cursor when all unprocessable',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtA","kind":445,"created_at":1700000100,"content":"x"}',
            ],
          );
          final mockCircle = MockCircleService(); // null decrypts
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.pollEvolutionEvents(circles: [testCircle]);

          expect(mockCircle.advanceGroupCursorLastSecs, isNull);
        },
      );

      test(
        'evolution poller does not advance cursor when auto-commit publish fails',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evtA","kind":445,"created_at":1700000100,"content":"sr"}',
            ],
          );
          // GroupUpdate with an auto-commit whose publish FAILS → left un-seen
          // → cursor must NOT advance past it (even though it has a created_at).
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson: '{"id":"commit","kind":445,"content":"x"}',
                evolutionMlsGroupId: [1, 2, 3, 4],
              ),
            ]
            ..publishEvolutionEventResults = [false];
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          await svc.pollEvolutionEvents(circles: [testCircle]);

          expect(mockCircle.advanceGroupCursorLastSecs, isNull);
        },
      );

      // ------------------------------------------------------------------
      // Receiver-side auto-commit (Fix #1)
      //
      // When MDK's `auto_commit_proposal` path stages a pending commit in
      // response to a peer's `SelfRemove`, the decrypt FFI hands us an
      // outbound `kind:445` evolution event plus the MLS group ID. The
      // service owes the group two things:
      //   1. publish the event so everyone converges on the same epoch, and
      //   2. merge the pending commit locally (or roll back on failure).
      // Without this, the local MLS epoch never advances and the departed
      // member sticks around in `get_members`.
      // ------------------------------------------------------------------
      test(
        'publishes evolution event and finalizes commit on success',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"proposal"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit-evt","kind":445,"content":"commit"}',
                evolutionMlsGroupId: [9, 9, 9, 9],
              ),
            ]
            // Publish succeeds.
            ..publishEvolutionEventResults = [true];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.groupUpdated, isTrue);
          // The service must have published the commit exactly once.
          expect(mockCircle.publishEvolutionEventCalls, hasLength(1));
          expect(
            mockCircle.publishEvolutionEventCalls.first['eventJson'],
            '{"id":"commit-evt","kind":445,"content":"commit"}',
          );
          expect(
            mockCircle.publishEvolutionEventCalls.first['relays'],
            testCircle.relays,
          );
          // And then finalized the pending commit with the right group ID.
          expect(mockCircle.finalizePendingCommitCalledWith, [
            [9, 9, 9, 9],
          ]);
          // MUST NOT have cleared on success.
          expect(mockCircle.clearPendingCommitCalledWith, isEmpty);
        },
      );

      test(
        'clears pending commit when evolution event publish fails',
        () async {
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"proposal"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit-evt","kind":445,"content":"commit"}',
                evolutionMlsGroupId: [1, 2, 3, 4],
              ),
            ]
            // Every relay rejected — publish reports failure.
            ..publishEvolutionEventResults = [false];

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.groupUpdated, isTrue);
          expect(mockCircle.publishEvolutionEventCalls, hasLength(1));
          // MUST roll back the dangling local commit — leaving it pending
          // would brick future message decryption for this circle.
          expect(mockCircle.clearPendingCommitCalledWith, [
            [1, 2, 3, 4],
          ]);
          expect(mockCircle.finalizePendingCommitCalledWith, isEmpty);
        },
      );

      test('clears pending commit when publish throws', () async {
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"proposal"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            const DecryptResult(
              groupUpdated: true,
              evolutionEventJson:
                  '{"id":"commit-evt","kind":445,"content":"commit"}',
              evolutionMlsGroupId: [5, 6, 7, 8],
            ),
          ]
          ..shouldThrowOnPublishEvolutionEvent = true;

        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
        );

        // MUST NOT propagate the publish exception — fetch should
        // degrade gracefully so polling can retry on the next cycle.
        final result = await svc.fetchMemberLocations(circle: testCircle);

        expect(result.groupUpdated, isTrue);
        expect(mockCircle.publishEvolutionEventCalls, hasLength(1));
        expect(mockCircle.clearPendingCommitCalledWith, [
          [5, 6, 7, 8],
        ]);
        expect(mockCircle.finalizePendingCommitCalledWith, isEmpty);
      });

      test(
        'does not publish when FFI reports groupUpdated without evolution event',
        () async {
          // Commit/ExternalJoin/PendingProposal/IgnoredProposal results all
          // surface as `groupUpdated: true` with no outbound event. In
          // those arms the service MUST NOT invoke publish or
          // finalize/clear — MDK has either already applied the commit or
          // has nothing for the receiver to carry out.
          final mockRelay = MockRelayService(
            groupMessages: [
              '{"id":"evt1","kind":445,"content":"plain-commit"}',
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

          final result = await svc.fetchMemberLocations(circle: testCircle);

          expect(result.groupUpdated, isTrue);
          expect(mockCircle.publishEvolutionEventCalls, isEmpty);
          expect(mockCircle.finalizePendingCommitCalledWith, isEmpty);
          expect(mockCircle.clearPendingCommitCalledWith, isEmpty);
        },
      );

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
              DecryptResult(
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
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: 'sender1',
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(minutes: 5)),
                expiresAt: now.add(const Duration(hours: 23)),
              ),
            ),
            DecryptResult(
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
            DecryptResult(
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
            DecryptResult(
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
            DecryptResult(
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
            DecryptResult(
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
            DecryptResult(
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
            DecryptResult(
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
        // `DecryptResult(groupUpdated: true)` is the minimal non-null
        // payload: it marks the event as successfully processed (so
        // `_seenEventIds` is populated under the mark-after-success
        // rule) without producing a cached location. Exactly what the
        // dedup-cap test wants to exercise.
        final mockCircle = MockCircleService()
          ..decryptLocationResults = List.filled(
            5,
            const DecryptResult(groupUpdated: true),
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
              const DecryptResult(groupUpdated: true),
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
              DecryptResult(
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
              DecryptResult(
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
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: 'senderB',
                  latitude: 40,
                  longitude: -100,
                  geohash: '9yz',
                  timestamp: now,
                  expiresAt: now.add(const Duration(hours: 23)),
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
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: now.subtract(const Duration(hours: 2)),
                expiresAt: now.subtract(const Duration(hours: 1)),
              ),
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
            const DecryptResult(groupUpdated: true),
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
              const DecryptResult(groupUpdated: true),
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
        'null decrypt result leaves the event eligible for retry on next fetch',
        () async {
          // First fetch's decrypt returns null (simulating an
          // Unprocessable / PreviouslyFailed — e.g., wrong-epoch
          // message). The event must NOT be in the seen set
          // afterwards. On the second fetch with the same event, the
          // now-healed epoch returns a successful decrypt and the
          // location surfaces.
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"wrong-epoch"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              // First attempt: wrong epoch → null.
              null,
              // Second attempt: epoch has caught up → success.
              DecryptResult(
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
            reason: 'null decrypt must not mark the event seen',
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
            const DecryptResult(groupUpdated: true),
            DecryptResult(
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
              const DecryptResult(groupUpdated: true),
              const DecryptResult(groupUpdated: true),
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
              const DecryptResult(groupUpdated: true),
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
            DecryptResult(location: locFor('alicepubkey')),
            DecryptResult(location: locFor('bobpubkey')),
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

          // Phase 2: relay delivers the auto-commit event that removes bob.
          // After finalizePendingCommit, getMembers returns only alice.
          relay.replaceAll([
            '{"id":"proposal","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit","kind":445,"content":"bob-removal"}',
                evolutionMlsGroupId: [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
              ],
            ]
            ..publishEvolutionEventResults = [true];

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

          // Phase 2: deliver the auto-commit event removing bob.
          relay.replaceAll([
            '{"id":"proposal","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit","kind":445,"content":"bob-removal"}',
                evolutionMlsGroupId: [10, 20, 30, 40],
              ),
            ]
            ..getMembersResults = [
              [
                TestCircleFactory.createMember(
                  pubkey: 'alicepubkey',
                  displayName: 'Alice',
                ),
              ],
            ]
            ..publishEvolutionEventResults = [true];
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

          // Deliver an evolution event (e.g., self-update) with no member
          // change — getMembers returns alice + bob unchanged.
          relay.replaceAll([
            '{"id":"self-update-evt","kind":445,"content":"update"}',
          ]);
          circle
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"self-update","kind":445,"content":"update"}',
                evolutionMlsGroupId: [10, 20, 30, 40],
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
            ]
            ..publishEvolutionEventResults = [true];
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

      test('does not evict when finalize fails', () async {
        final (:svc, :circle, :relay) = await buildSeededService();
        expect(svc.debugCachedLocationCount, 2);

        // Deliver an evolution event; finalize will throw.
        relay.replaceAll([
          '{"id":"proposal","kind":445,"content":"bob-remove"}',
        ]);
        circle
          ..decryptLocationResults = [
            const DecryptResult(
              groupUpdated: true,
              evolutionEventJson:
                  '{"id":"commit","kind":445,"content":"bob-removal"}',
              evolutionMlsGroupId: [10, 20, 30, 40],
            ),
          ]
          ..publishEvolutionEventResults = [true]
          ..shouldThrowOnFinalizePendingCommit = true;
        await svc.fetchMemberLocations(circle: evictionCircle);

        // finalize threw → _evictDepartedMembers was never entered.
        expect(
          svc.debugCachedLocationCount,
          2,
          reason: 'finalize failed — cache must be untouched for retry',
        );
        // getMembers must NOT have been called (eviction skipped on throw).
        final getMembersCalls = circle.methodCalls
            .where((c) => c == 'getMembers')
            .length;
        expect(
          getMembersCalls,
          0,
          reason: 'eviction path must not run when finalize throws',
        );
      });

      test(
        'does not evict when publish fails (clearPendingCommit path)',
        () async {
          final (:svc, :circle, :relay) = await buildSeededService();
          expect(svc.debugCachedLocationCount, 2);

          // Deliver the proposal; publish will fail (returns false).
          relay.replaceAll([
            '{"id":"proposal","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit","kind":445,"content":"bob-removal"}',
                evolutionMlsGroupId: [10, 20, 30, 40],
              ),
            ]
            ..publishEvolutionEventResults = [false];
          await svc.fetchMemberLocations(circle: evictionCircle);

          // publish failed → clearPendingCommit path → epoch NOT advanced.
          expect(
            svc.debugCachedLocationCount,
            2,
            reason: 'publish failed — cache must be untouched',
          );
          expect(
            circle.clearPendingCommitCalledWith,
            isNotEmpty,
            reason: 'clearPendingCommit must be called on publish failure',
          );
          expect(
            circle.finalizePendingCommitCalledWith,
            isEmpty,
            reason: 'finalize must not be called when publish fails',
          );
          // getMembers must not be called — eviction only runs after finalize.
          expect(circle.methodCalls, isNot(contains('getMembers')));
        },
      );

      test('retries on next fetch when getMembers fails transiently after '
          'finalize', () async {
        // Review-driven (security-reviewer MEDIUM): if getMembers throws
        // after finalizePendingCommit has advanced the local epoch, the
        // departed member has been removed from MDK but remains in the
        // in-memory cache AND the persistent store. Without a retry, the
        // stale pin lingers until the next message-triggered cycle (which
        // may never come for a silently-departed peer) or the 30-min
        // grace-window eviction (memory only, not persistent). The
        // service must queue the eviction and retry on the next fetch.
        final (:svc, :circle, :relay) = await buildSeededService();
        expect(svc.debugCachedLocationCount, 2);

        // Phase 2: deliver the commit event that removes bob. finalize
        // succeeds (epoch advances), but getMembers throws once.
        relay.replaceAll([
          '{"id":"proposal","kind":445,"content":"bob-remove"}',
        ]);
        circle
          ..decryptLocationResults = [
            const DecryptResult(
              groupUpdated: true,
              evolutionEventJson:
                  '{"id":"commit","kind":445,"content":"bob-removal"}',
              evolutionMlsGroupId: [10, 20, 30, 40],
            ),
          ]
          ..publishEvolutionEventResults = [true]
          ..getMembersThrowCount = 1;

        await svc.fetchMemberLocations(circle: evictionCircle);

        // Cache must be untouched — we could not determine the post-commit
        // roster, so pruning would be unsafe.
        expect(
          svc.debugCachedLocationCount,
          2,
          reason: 'getMembers threw — eviction deferred, cache intact',
        );
        // finalize ran (epoch advanced) before getMembers threw.
        expect(
          circle.finalizePendingCommitCalledWith,
          isNotEmpty,
          reason: 'finalize must run before the throwing getMembers call',
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

          // Deliver bob's removal proposal via the evolution-poll path
          // (no location-fetch in between). finalize advances the local
          // epoch; getMembers returns only alice.
          relay.replaceAll([
            '{"id":"proposal-poll","kind":445,"content":"bob-remove"}',
          ]);
          circle
            ..decryptLocationResults = [
              const DecryptResult(
                groupUpdated: true,
                evolutionEventJson:
                    '{"id":"commit-poll","kind":445,"content":"bob-removal"}',
                evolutionMlsGroupId: [10, 20, 30, 40],
              ),
            ]
            ..publishEvolutionEventResults = [true]
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
          expect(circle.methodCalls, contains('finalizePendingCommit'));
          expect(circle.methodCalls, contains('getMembers'));
          expect(circle.methodCalls, contains('removeLastKnownMember'));
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
              DecryptResult(
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

      test(
        'rehydrates from the persistent store on the next fetch after pause',
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

          // First fetch hydrates.
          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, hasLength(1));
          expect(first.locations.first.latitude, 41.0);

          svc.onAppPaused();
          expect(svc.debugCachedLocationCount, 0);

          // Second fetch — should rehydrate from the persistent store.
          final second = await svc.fetchMemberLocations(circle: testCircle);
          expect(second.locations, hasLength(1));
          expect(second.locations.first.latitude, 41.0);

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
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: 'sender1',
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
              DecryptResult(
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
        await svc.removeCircle(removableCircle.nostrGroupId);

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

    // -------------------------------------------------------------------------
    // M2 — avatar receive routing via _ingestAvatar
    // -------------------------------------------------------------------------

    group('M2 avatar receive routing', () {
      final testCircle = TestCircleFactory.createCircle(
        displayName: 'AvatarCircle',
        members: [
          TestCircleFactory.createMember(
            pubkey: 'senderabc',
            displayName: 'Alice',
          ),
        ],
      );

      test('fetchMemberLocations calls ingestIncomingAvatarMessage for '
          'successfully decrypted events', () async {
        const senderPubkey = 'senderabc';
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
        );
        // Provide a decrypt result so the event passes the null-check
        // (decrypt==null → continue, ingest skipped by design).
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: senderPubkey,
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

        // ingestIncomingAvatarMessage must be called once per successfully
        // decrypted event.
        expect(mockCircle.methodCalls, contains('ingestIncomingAvatarMessage'));
        expect(mockCircle.ingestAvatarMessageCalls, hasLength(1));
      });

      test(
        'fetchMemberLocations: complete==true updates avatarContentHash in cache',
        () async {
          const senderPubkey = 'senderabc';
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
          );
          // Seed cache with a location for the sender; configure ingest to
          // report complete.
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ]
            ..ingestResult = const AvatarIngestResult(
              accepted: true,
              complete: true,
              senderPubkeyHex: senderPubkey,
            );

          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          // First fetch populates the cache.
          final first = await svc.fetchMemberLocations(circle: testCircle);
          expect(first.locations, hasLength(1));

          // After complete==true, groupUpdated must be true.
          expect(first.groupUpdated, isTrue);

          // The location's avatarContentHash must be non-null and non-empty.
          final loc = first.locations.first;
          expect(loc.avatarContentHash, isNotNull);
          expect(loc.avatarContentHash, isNotEmpty);
        },
      );

      test(
        'fetchMemberLocations: complete==false does NOT update avatarContentHash',
        () async {
          const senderPubkey = 'senderabc';
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
                  latitude: 37,
                  longitude: -122,
                  geohash: '9q8',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ];
          // Default ingestResult: accepted=false, complete=false.
          final svc = LocationSharingService(
            circleService: mockCircle,
            relayService: mockRelay,
          );

          final result = await svc.fetchMemberLocations(circle: testCircle);
          final loc = result.locations.first;
          expect(loc.avatarContentHash, isNull);
        },
      );

      test(
        'fetchMemberLocations: ingest error does not bubble to caller',
        () async {
          const senderPubkey = 'senderabc';
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
          );
          // Provide a decrypt result so the event is not skipped.
          final mockCircle = MockCircleService()
            ..shouldThrowOnIngestAvatarMessage = true
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
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

          // Must complete without throwing even if ingest fails.
          expect(
            () => svc.fetchMemberLocations(circle: testCircle),
            returnsNormally,
          );
        },
      );

      // HIGH-2: onAvatarComplete fires and includes (mlsGroupId, pubkeyHex)
      test('fetchMemberLocations: onAvatarComplete callback fires when '
          'ingest complete==true (HIGH-2)', () async {
        const senderPubkey = 'senderabc';
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: senderPubkey,
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ]
          ..ingestResult = const AvatarIngestResult(
            accepted: true,
            complete: true,
            senderPubkeyHex: senderPubkey,
          );

        final callbackArgs = <(List<int>, String)>[];
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
          onAvatarComplete: (mlsGroupId, pubkeyHex) {
            callbackArgs.add((mlsGroupId, pubkeyHex));
          },
        );

        await svc.fetchMemberLocations(circle: testCircle);

        expect(
          callbackArgs,
          hasLength(1),
          reason:
              'onAvatarComplete must be called once when '
              'ingest.complete == true',
        );
        expect(
          callbackArgs.first.$2,
          equals(senderPubkey),
          reason: 'callback must carry the sender pubkey hex',
        );
        // The mlsGroupId must match the circle's group id.
        expect(
          callbackArgs.first.$1,
          equals(testCircle.mlsGroupId),
          reason: 'callback must carry the circle mlsGroupId',
        );
      });

      test('fetchMemberLocations: onAvatarComplete NOT called when '
          'ingest complete==false', () async {
        const senderPubkey = 'senderabc';
        final mockRelay = MockRelayService(
          groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
        );
        final mockCircle = MockCircleService()
          ..decryptLocationResults = [
            DecryptResult(
              location: DecryptedLocation(
                senderPubkey: senderPubkey,
                latitude: 37,
                longitude: -122,
                geohash: '9q8',
                timestamp: DateTime.now(),
                expiresAt: DateTime.now().add(const Duration(hours: 23)),
              ),
            ),
          ];
        // Default: complete=false.

        var callbackFired = false;
        final svc = LocationSharingService(
          circleService: mockCircle,
          relayService: mockRelay,
          onAvatarComplete: (_, _) {
            callbackFired = true;
          },
        );

        await svc.fetchMemberLocations(circle: testCircle);

        expect(
          callbackFired,
          isFalse,
          reason:
              'onAvatarComplete must not fire when ingest.complete == false',
        );
      });

      test(
        'avatarContentHash change-token is deterministic (not wall-clock)',
        () async {
          // The token stored in MemberLocation.avatarContentHash must be
          // derived from stable ingest data (senderPubkeyHex), not from
          // DateTime.now().millisecondsSinceEpoch. Two successive fetches
          // that produce the same ingest result must yield the same token.
          const senderPubkey = 'deadbeefcafe';
          final ingestResult = const AvatarIngestResult(
            accepted: true,
            complete: true,
            senderPubkeyHex: senderPubkey,
          );

          final testCircleLocal = TestCircleFactory.createCircle(
            displayName: 'Token test',
            members: [TestCircleFactory.createMember(pubkey: senderPubkey)],
          );

          // First run: fetch, collect token.
          final mockRelay1 = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"a"}'],
          );
          final mockCircle1 = MockCircleService()
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
                  latitude: 10,
                  longitude: 20,
                  geohash: 'u09t',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ]
            ..ingestResult = ingestResult;

          final svc1 = LocationSharingService(
            circleService: mockCircle1,
            relayService: mockRelay1,
          );
          final first = await svc1.fetchMemberLocations(
            circle: testCircleLocal,
          );
          final token1 = first.locations.first.avatarContentHash;
          expect(token1, isNotNull, reason: 'token must be set after ingest');

          // Second run (independent service, same ingest): token must match.
          final mockRelay2 = MockRelayService(
            groupMessages: ['{"id":"evt2","kind":445,"content":"b"}'],
          );
          final mockCircle2 = MockCircleService()
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
                  latitude: 10,
                  longitude: 20,
                  geohash: 'u09t',
                  timestamp: DateTime.now(),
                  expiresAt: DateTime.now().add(const Duration(hours: 23)),
                ),
              ),
            ]
            ..ingestResult = ingestResult;

          final svc2 = LocationSharingService(
            circleService: mockCircle2,
            relayService: mockRelay2,
          );
          final second = await svc2.fetchMemberLocations(
            circle: testCircleLocal,
          );
          final token2 = second.locations.first.avatarContentHash;

          expect(
            token2,
            equals(token1),
            reason:
                'change-token must be deterministic (same ingest result → '
                'same token) and must NOT vary with wall-clock time',
          );
        },
      );

      // Avatars are always received — _ingestAvatar runs whenever a
      // complete avatar message arrives (no opt-out gate).
      test(
        '_ingestAvatar ingests incoming avatar messages (always received)',
        () async {
          const senderPubkey = 'senderabc';
          final mockRelay = MockRelayService(
            groupMessages: ['{"id":"evt1","kind":445,"content":"data"}'],
          );
          final mockCircle = MockCircleService()
            ..decryptLocationResults = [
              DecryptResult(
                location: DecryptedLocation(
                  senderPubkey: senderPubkey,
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

          final testCircleLocal = TestCircleFactory.createCircle(
            displayName: 'GateNullTest',
            members: [
              TestCircleFactory.createMember(
                pubkey: senderPubkey,
                displayName: 'Alice',
              ),
            ],
          );

          await svc.fetchMemberLocations(circle: testCircleLocal);

          // Avatars are always received — ingest proceeds.
          expect(
            mockCircle.methodCalls,
            contains('ingestIncomingAvatarMessage'),
          );
        },
      );
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
        latitude: 38,
        longitude: -121,
        geohash: '9q9',
        timestamp: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 23)),
      ),
    );
  }

  @override
  Future<EncryptedLocation> encryptLocation({
    required List<int> mlsGroupId,
    required String senderPubkeyHex,
    required double latitude,
    required double longitude,
    required int updateIntervalSecs,
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
  Future<void> leaveCircle({
    required List<int> mlsGroupId,
    required String selfPubkeyHex,
  }) async {}

  @override
  Future<void> removeMember({
    required List<int> mlsGroupId,
    required String memberPubkeyHex,
  }) async {}

  @override
  Future<Invitation?> processGiftWrappedInvitation({
    required List<int> identitySecretBytes,
    required String giftWrapEventJson,
  }) async => throw UnimplementedError();

  @override
  Future<void> finalizePendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<void> clearPendingCommit(List<int> mlsGroupId) async {}

  @override
  Future<bool> publishEvolutionEvent({
    required String eventJson,
    required List<String> relays,
    required String label,
  }) async => true;

  @override
  Future<SignedKeyPackageEvent> signKeyPackageEvent({
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
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();
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
