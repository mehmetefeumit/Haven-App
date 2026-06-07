/// Unit tests for stale-location TTL eviction in LocationSharingService.
///
/// These are pure Dart tests (no emulator, no FFI) that verify the
/// in-memory cache eviction is driven deterministically by the injected
/// clock rather than the wall clock. Each test must FAIL if eviction
/// logic breaks — assertions cover both the return count and the map
/// contents, not just the absence of exceptions.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import '../mocks/mock_circle_service.dart';
import '../mocks/mock_relay_service.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a [MemberLocation] with the minimum required fields for eviction
/// tests. Coordinates are inert dummy values — this path is non-crypto.
MemberLocation _loc({
  required String pubkey,
  required DateTime expiresAt,
}) {
  return MemberLocation(
    pubkey: pubkey,
    latitude: 0,
    longitude: 0,
    geohash: 'u173',
    timestamp: expiresAt.subtract(const Duration(hours: 1)),
    expiresAt: expiresAt,
  );
}

/// Builds a LocationSharingService wired to minimal no-op mocks and the
/// supplied [now] clock. Tests only call evictStaleLocationsForTest, so
/// the mock services are never invoked.
LocationSharingService _service({
  required DateTime Function() now,
  Duration cacheEvictionGrace = Duration.zero,
}) {
  return LocationSharingService(
    circleService: MockCircleService(),
    relayService: MockRelayService(),
    cacheEvictionGrace: cacheEvictionGrace,
    now: now,
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  final fixedNow = DateTime(2026, 6, 7, 12);

  group('LocationSharingService.evictStaleLocationsForTest', () {
    test(
      'Case 1: entry with expiresAt before fixedNow (grace=0) is evicted',
      () {
        final svc = _service(now: () => fixedNow);

        // expiresAt is one second before fixedNow → cutoff = fixedNow,
        // so expiresAt.isBefore(cutoff) is true → must be evicted.
        final cache = <String, MemberLocation>{
          'alice': _loc(
            pubkey: 'alice',
            expiresAt: fixedNow.subtract(const Duration(seconds: 1)),
          ),
        };

        final evicted = svc.evictStaleLocationsForTest(cache);

        expect(
          evicted,
          1,
          reason: 'one stale entry must be reported as evicted',
        );
        expect(
          cache,
          isEmpty,
          reason: 'the stale key must be removed from the map',
        );
      },
    );

    test(
      'Case 2: entry with expiresAt after fixedNow (grace=0) is retained',
      () {
        final svc = _service(now: () => fixedNow);

        // expiresAt is one second after fixedNow → still fresh.
        final cache = <String, MemberLocation>{
          'bob': _loc(
            pubkey: 'bob',
            expiresAt: fixedNow.add(const Duration(seconds: 1)),
          ),
        };

        final evicted = svc.evictStaleLocationsForTest(cache);

        expect(evicted, 0, reason: 'no entries should be evicted when fresh');
        expect(
          cache,
          hasLength(1),
          reason: 'the fresh entry must remain in the map',
        );
        expect(cache.containsKey('bob'), isTrue);
      },
    );

    test(
      'Case 3: grace boundary — 29 min past expiresAt retained, '
          '31 min past evicted',
      () {
        // cacheEvictionGrace = 30 minutes.
        // cutoff = fixedNow - 30 min.
        // Entry A: expiresAt = fixedNow - 29 min → after cutoff → retained.
        // Entry B: expiresAt = fixedNow - 31 min → before cutoff → evicted.
        final svc = _service(
          now: () => fixedNow,
          cacheEvictionGrace: const Duration(minutes: 30),
        );

        final cache = <String, MemberLocation>{
          'within_grace': _loc(
            pubkey: 'within_grace',
            expiresAt: fixedNow.subtract(const Duration(minutes: 29)),
          ),
          'past_grace': _loc(
            pubkey: 'past_grace',
            expiresAt: fixedNow.subtract(const Duration(minutes: 31)),
          ),
        };

        final evicted = svc.evictStaleLocationsForTest(cache);

        expect(
          evicted,
          1,
          reason: 'exactly one entry (past_grace) must be evicted',
        );
        expect(
          cache.containsKey('within_grace'),
          isTrue,
          reason: '29-min-old entry is still within the 30-min grace window',
        );
        expect(
          cache.containsKey('past_grace'),
          isFalse,
          reason: '31-min-old entry has passed the 30-min grace window',
        );
      },
    );

    test(
      'Case 4: advancing the injected clock drives the eviction decision',
      () {
        // Shared entry: expiresAt = fixedNow - 1 min.
        // Service A clock = fixedNow - 2 min → cutoff = fixedNow - 2 min,
        //   expiresAt (fixedNow-1min) is AFTER cutoff → retained.
        // Service B clock = fixedNow + 1 min → cutoff = fixedNow + 1 min,
        //   expiresAt (fixedNow-1min) is BEFORE cutoff → evicted.
        final expiresAt = fixedNow.subtract(const Duration(minutes: 1));

        // Build both caches independently (same data, different maps).
        final cacheEarly = <String, MemberLocation>{
          'charlie': _loc(pubkey: 'charlie', expiresAt: expiresAt),
        };
        final cacheLate = <String, MemberLocation>{
          'charlie': _loc(pubkey: 'charlie', expiresAt: expiresAt),
        };

        final earlyClockSvc = _service(
          now: () => fixedNow.subtract(const Duration(minutes: 2)),
        );
        final lateClockSvc = _service(
          now: () => fixedNow.add(const Duration(minutes: 1)),
        );

        final evictedEarly =
            earlyClockSvc.evictStaleLocationsForTest(cacheEarly);
        final evictedLate =
            lateClockSvc.evictStaleLocationsForTest(cacheLate);

        expect(evictedEarly, 0, reason: 'early clock: entry is not yet stale');
        expect(
          cacheEarly.containsKey('charlie'),
          isTrue,
          reason: 'early clock: entry must remain in map',
        );

        expect(evictedLate, 1, reason: 'late clock: entry has passed expiry');
        expect(
          cacheLate.containsKey('charlie'),
          isFalse,
          reason: 'late clock: entry must be removed from map',
        );
      },
    );
  });
}
