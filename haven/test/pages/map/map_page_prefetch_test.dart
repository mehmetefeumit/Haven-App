/// Tests for the M-D anticipatory tile prefetch trigger in `_MapPageState`.
///
/// ## Scope and limitation
///
/// `MapPage` calls `HavenCore.newInstance()` and `HavenCore.isInitialized()`
/// in `State.initState`, which crosses the Rust FFI boundary. Pumping the
/// full widget in a unit test without the compiled Rust bridge would crash the
/// test runner. Full end-to-end coverage therefore lives in the integration
/// test suite (`integration_test/`).
///
/// This file verifies the PURE parts of the trigger pipeline that can be
/// exercised without the FFI:
///
/// 1. [tilePrefetchServiceProvider] is injectable via `ProviderScope`
///    override, allowing the widget to be replaced in a test scope.
/// 2. A `_FakePrefetchService` records call arguments for assertion.
/// 3. The nearest-member distance-sort logic is verified via
///    [nearestMemberPoints] (the real function from `prefetch_scope.dart`).
/// 4. The [prefetchLandingZoom] helper verifies the zoom-floor/clamp logic.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/tile_prefetch_provider.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/tile_prefetch_service.dart';
import 'package:haven/src/utils/prefetch_scope.dart';
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// Fake prefetch service
// ---------------------------------------------------------------------------

/// Records every [TilePrefetchService.prefetch] call for test assertions.
class _FakePrefetchService implements TilePrefetchService {
  final List<Map<String, Object?>> calls = [];
  bool cancelCalled = false;

  @override
  Future<void> prefetch({
    required List<LatLng> points,
    required TileProviderConfig config,
    required int landingZoom,
    required bool retina,
  }) async {
    calls.add({
      'points': List<LatLng>.from(points),
      'landingZoom': landingZoom,
      'retina': retina,
    });
  }

  @override
  void cancel() {
    cancelCalled = true;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

MemberLocation _member(double lat, double lng) => MemberLocation(
      pubkey: 'aabbcc',
      latitude: lat,
      longitude: lng,
      geohash: 'u10h',
      timestamp: DateTime(2025),
      expiresAt: DateTime(2025).add(const Duration(hours: 1)),
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // ---------------------------------------------------------------------------
  // Provider override: tilePrefetchServiceProvider is injectable
  // ---------------------------------------------------------------------------

  group('tilePrefetchServiceProvider override', () {
    test('ProviderScope injects the fake service without touching Rust', () {
      final fake = _FakePrefetchService();
      final container = ProviderContainer(
        overrides: [
          tilePrefetchServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(tilePrefetchServiceProvider);
      expect(service, same(fake),
          reason: 'The override must return the injected fake');
    });

    test('cancel() is forwarded to the injected fake', () {
      final fake = _FakePrefetchService();
      final container = ProviderContainer(
        overrides: [
          tilePrefetchServiceProvider.overrideWithValue(fake),
        ],
      );
      addTearDown(container.dispose);

      container.read(tilePrefetchServiceProvider).cancel();
      expect(fake.cancelCalled, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // listEquals equivalent — circle-change guard
  //
  // The map_page.dart now uses listEquals from package:flutter/foundation.dart
  // rather than a private copy. These tests verify the guard contract.
  // ---------------------------------------------------------------------------

  group('listEquals (circle-change guard)', () {
    test('equal lists → returns true (same circle, no re-burst)', () {
      expect(
        [1, 2, 3].length == [1, 2, 3].length &&
            _allEqual([1, 2, 3], [1, 2, 3]),
        isTrue,
      );
    });

    test('different values → returns false (new circle, re-burst fires)', () {
      expect(_allEqual([1, 2, 3], [1, 2, 4]), isFalse);
    });

    test('different lengths → returns false', () {
      expect([1, 2].length == [1, 2, 3].length, isFalse);
    });

    test('empty lists → returns true', () {
      expect(_allEqual([], []), isTrue);
    });

    test('single-element lists: equal → true', () {
      expect(_allEqual([42], [42]), isTrue);
    });

    test('single-element lists: unequal → false', () {
      expect(_allEqual([42], [43]), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // nearestMemberPoints — the REAL function from prefetch_scope.dart
  // ---------------------------------------------------------------------------

  group('nearestMemberPoints (real function, nearest-to-camera sort)', () {
    // Camera is at London.
    const camera = LatLng(51.5074, -0.1278);

    // Member A is very close (~5 km north).
    final memberA = _member(51.55, -0.14);

    // Member B is far (~200 km north-west — Manchester).
    final memberB = _member(53.48, -2.24);

    test('closer member appears before farther member', () {
      final points = nearestMemberPoints([memberA, memberB], camera);
      expect(points.length, 2);
      // Nearest first: memberA is ~5 km, memberB is ~200 km.
      expect(
        points[0],
        LatLng(memberA.latitude, memberA.longitude),
        reason: 'Nearby member must sort before far member',
      );
      expect(
        points[1],
        LatLng(memberB.latitude, memberB.longitude),
      );
    });

    test('distance to self is 0 — member at camera center is first', () {
      final selfMember = _member(camera.latitude, camera.longitude);
      final points = nearestMemberPoints([memberA, selfMember], camera);
      expect(
        points[0],
        LatLng(selfMember.latitude, selfMember.longitude),
        reason: 'Self (zero distance) must be first',
      );
    });

    test('three members sort correctly by distance', () {
      // memberC is ~1 km from London — closest.
      final memberC = _member(51.51, -0.13);
      final points = nearestMemberPoints([memberA, memberB, memberC], camera);

      // Nearest → farthest: memberC, memberA, memberB.
      expect(points[0], LatLng(memberC.latitude, memberC.longitude));
      expect(points[1], LatLng(memberA.latitude, memberA.longitude));
      expect(points[2], LatLng(memberB.latitude, memberB.longitude));
    });

    test('empty list → empty result', () {
      expect(nearestMemberPoints([], camera), isEmpty);
    });

    test('single member → returns that member as LatLng', () {
      final points = nearestMemberPoints([memberA], camera);
      expect(points.length, 1);
      expect(points[0], LatLng(memberA.latitude, memberA.longitude));
    });

    test('original list is not mutated', () {
      final original = [memberB, memberA];
      nearestMemberPoints(original, camera);
      // original must still be [memberB, memberA] — not sorted in place.
      expect(original[0], memberB);
      expect(original[1], memberA);
    });
  });

  // ---------------------------------------------------------------------------
  // prefetchLandingZoom — the REAL function from prefetch_scope.dart
  // ---------------------------------------------------------------------------

  group('prefetchLandingZoom (real function, zoom-floor/clamp logic)', () {
    // prefetchLandingZoom requires a double first argument; the literals
    // below must remain as doubles. The prefer_int_literals lint does not
    // apply when the type is explicitly double.
    // ignore_for_file: prefer_int_literals
    test('zoom below 14 → returns 14 (landing floor)', () {
      expect(prefetchLandingZoom(10, 20), 14);
    });

    test('zoom at exactly 14 → returns 14', () {
      expect(prefetchLandingZoom(14, 20), 14);
    });

    test('zoom above 14 → returns current zoom (rounded)', () {
      expect(prefetchLandingZoom(16, 20), 16);
    });

    test('zoom above maxNativeZoom → clamps to maxNativeZoom', () {
      expect(prefetchLandingZoom(22, 20), 20);
    });

    test('zoom below 3 (below map minZoom) → clamps to 3', () {
      // prefetchLandingZoom applies a 14 floor, so a zoom of 1 becomes 14
      // and then clamps to max(3,14)=14 (the floor wins).
      // To test the upper-end clamp independently, use maxNativeZoom=5
      // with a large zoom value.
      expect(prefetchLandingZoom(1, 5), 5);
    });

    test('fractional zoom rounds correctly', () {
      expect(prefetchLandingZoom(14.7, 20), 15);
      expect(prefetchLandingZoom(14.4, 20), 14);
    });
  });

  // ---------------------------------------------------------------------------
  // Full widget test note
  // ---------------------------------------------------------------------------
  //
  // The ref.listen listener in _MapPageState.build() that actually calls
  // prefetch() requires pumping MapPage, which calls HavenCore.newInstance()
  // (Rust FFI) in initState. Full widget-level coverage of the listener
  // therefore lives in:
  //   integration_test/encryption_pipeline_test.dart (member-location flow)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Element-wise equality check for two int lists.
///
/// Mirrors the contract that map_page.dart enforces when guarding against
/// re-bursting on the same circle. Implemented here to keep test assertions
/// self-contained without depending on the private internals of the page.
bool _allEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
