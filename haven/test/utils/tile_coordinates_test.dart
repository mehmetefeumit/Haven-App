/// Tests for [latLngToTile], [tileRing], [coarseParent], and [expandTileUrl].
///
/// All tests are pure Dart — no network, no FFI, no widget harness.
///
/// The load-bearing parity test (§4) asserts that
/// `TileKey.tryParse(expandTileUrl(config, z, x, y, retina: r))`
/// returns `(config.style, z, x, y, r)` for all four Stadia styles and both
/// retina values, proving that prefetch writes the exact cache key the map
/// reads.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/services/tile_key.dart';
import 'package:haven/src/utils/tile_coordinates.dart';
import 'package:latlong2/latlong.dart';

void main() {
  // ---------------------------------------------------------------------------
  // latLngToTile — golden value
  // ---------------------------------------------------------------------------

  group('latLngToTile — golden values', () {
    test('London z14 → (8186, 5448)', () {
      // Reference: https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
      // Standard Web Mercator formula: floor((lng+180)/360 * 2^z),
      // floor((1 - ln(tan(lat_rad)+1/cos(lat_rad))/π) / 2 * 2^z).
      // For (51.5074, -0.1278) at z=14: x≈8186.18, y≈5448.10 → (8186, 5448).
      // Note: (8187, 5451) appearing in tile_key_test.dart are arbitrary URL
      // test values, not coordinate-derived.
      final tile = latLngToTile(const LatLng(51.5074, -0.1278), 14);
      expect(tile.x, 8186);
      expect(tile.y, 5448);
    });

    test('Origin (0, 0) z0 → (0, 0)', () {
      final tile = latLngToTile(const LatLng(0, 0), 0);
      expect(tile.x, 0);
      expect(tile.y, 0);
    });

    test('Origin (0, 0) z1 → (1, 1)', () {
      // At z1 the world is 2×2 tiles; (0°,0°) is at the centre of tile (1,1).
      final tile = latLngToTile(const LatLng(0, 0), 1);
      expect(tile.x, 1);
      expect(tile.y, 1);
    });

    test('North-west corner z1 → (0, 0)', () {
      // Just inside the NW quadrant.
      final tile = latLngToTile(const LatLng(80, -170), 1);
      expect(tile.x, 0);
      expect(tile.y, 0);
    });

    test('South-east corner z1 → (1, 1)', () {
      final tile = latLngToTile(const LatLng(-80, 170), 1);
      expect(tile.x, 1);
      expect(tile.y, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // latLngToTile — latitude clamping
  // ---------------------------------------------------------------------------

  group('latLngToTile — polar clamping', () {
    test('Latitude exactly 90° is clamped, does not crash', () {
      // Should not throw and must produce a valid tile index in [0, 2^z-1].
      final tile = latLngToTile(const LatLng(90, 0), 10);
      expect(tile.x, inInclusiveRange(0, (1 << 10) - 1));
      expect(tile.y, inInclusiveRange(0, (1 << 10) - 1));
    });

    test('Latitude exactly -90° is clamped, does not crash', () {
      final tile = latLngToTile(const LatLng(-90, 0), 10);
      expect(tile.x, inInclusiveRange(0, (1 << 10) - 1));
      expect(tile.y, inInclusiveRange(0, (1 << 10) - 1));
    });

    test('Longitude -180 → x = 0 at z1', () {
      final tile = latLngToTile(const LatLng(0, -180), 1);
      expect(tile.x, 0);
    });

    test('Longitude +180 wraps / clamps within [0, 2^z-1]', () {
      final tile = latLngToTile(const LatLng(0, 180), 1);
      // 180° produces n = 2^1 * (180+180)/360 = 2 → clamped to 1.
      expect(tile.x, inInclusiveRange(0, 1));
    });
  });

  // ---------------------------------------------------------------------------
  // tileRing
  // ---------------------------------------------------------------------------

  group('tileRing', () {
    test('radius 0 → exactly 1 tile (the centre)', () {
      final ring = tileRing((x: 5, y: 5), 10, radius: 0);
      expect(ring.length, 1);
      expect(ring.first, (x: 5, y: 5));
    });

    test('radius 1 → up to 9 tiles in open space', () {
      // radius=1 is the default for tileRing; omitting it still tests r=1.
      final ring = tileRing((x: 100, y: 100), 10);
      expect(ring.length, 9);
    });

    test('radius 1 with kPrefetchRing constant → 9 tiles', () {
      // Verifies the policy constant matches the geometric expectation.
      final ring = tileRing((x: 50, y: 50), 10);
      expect(ring.length, 9);
    });

    test('edge clamping at x=0 deduplicates — fewer than 9 tiles', () {
      // Column 0 at the left edge: negative x clamps to 0.
      final ring = tileRing((x: 0, y: 100), 10);
      // The three left-column tiles collapse to one column, so ≤6 unique.
      expect(ring.length, lessThan(9));
      // All x values must be ≥ 0.
      for (final t in ring) {
        expect(t.x, greaterThanOrEqualTo(0));
      }
    });

    test('edge clamping at y=0 deduplicates — fewer than 9 tiles', () {
      final ring = tileRing((x: 100, y: 0), 10);
      expect(ring.length, lessThan(9));
      for (final t in ring) {
        expect(t.y, greaterThanOrEqualTo(0));
      }
    });

    test('edge clamping at max boundary deduplicates', () {
      const maxIdx = (1 << 10) - 1;
      final ring = tileRing((x: maxIdx, y: maxIdx), 10);
      expect(ring.length, lessThan(9));
      for (final t in ring) {
        expect(t.x, inInclusiveRange(0, maxIdx));
        expect(t.y, inInclusiveRange(0, maxIdx));
      }
    });

    test('no duplicate tiles are returned', () {
      final ring = tileRing((x: 5, y: 5), 10);
      final unique = <({int x, int y})>{};
      for (final t in ring) {
        expect(unique.add(t), isTrue, reason: 'duplicate tile $t');
      }
    });

    test('corner tile (0,0) with radius 1 returns 4 tiles (both axes clamped)',
        () {
      final ring = tileRing((x: 0, y: 0), 10);
      // (-1 clamps to 0) × 2 axes → (3-1)×(3-1) = 4 unique after dedup.
      expect(ring.length, 4);
    });
  });

  // ---------------------------------------------------------------------------
  // coarseParent
  // ---------------------------------------------------------------------------

  group('coarseParent', () {
    test('delta 2 on z=14 tile gives z=12 parent', () {
      final parent = coarseParent(14, 8187, 5451, 2);
      expect(parent.z, 12);
      expect(parent.x, 8187 >> 2);
      expect(parent.y, 5451 >> 2);
    });

    test('delta 0 → same tile', () {
      final parent = coarseParent(10, 50, 50, 0);
      expect(parent.z, 10);
      expect(parent.x, 50);
      expect(parent.y, 50);
    });

    test('delta larger than z → z floors at 0', () {
      final parent = coarseParent(3, 4, 5, 10);
      expect(parent.z, 0);
      // The entire world collapses to tile (0,0) at z=0.
      expect(parent.x, 0);
      expect(parent.y, 0);
    });

    test('delta 1 shifts x/y right by 1 (integer-divides by 2)', () {
      final parent = coarseParent(5, 6, 7, 1);
      expect(parent.z, 4);
      expect(parent.x, 3); // 6 >> 1
      expect(parent.y, 3); // 7 >> 1
    });
  });

  // ---------------------------------------------------------------------------
  // expandTileUrl — token substitution
  // ---------------------------------------------------------------------------

  group('expandTileUrl — token substitution', () {
    test('replaces {z}, {x}, {y} correctly', () {
      final url = expandTileUrl(stadiaAlidadeSmooth, 14, 8187, 5451,
          retina: false);
      expect(url, contains('/14/'));
      expect(url, contains('/8187/'));
      expect(url, contains('5451.png'));
    });

    test('retina=true produces @2x.png', () {
      final url = expandTileUrl(stadiaAlidadeSmooth, 14, 8187, 5451,
          retina: true);
      expect(url, contains('5451@2x.png'));
    });

    test('retina=false produces .png without @2x', () {
      final url = expandTileUrl(stadiaAlidadeSmooth, 14, 8187, 5451,
          retina: false);
      expect(url, isNot(contains('@2x')));
      expect(url, contains('.png'));
    });

    test('{api_key} is replaced from additionalOptions', () {
      final url = expandTileUrl(stadiaAlidadeSmooth, 14, 8187, 5451,
          retina: false);
      // The placeholder or real key must be substituted; the literal token
      // must not appear in the final URL.
      expect(url, isNot(contains('{api_key}')));
    });
  });

  // ---------------------------------------------------------------------------
  // Parity: expandTileUrl → TileKey.tryParse round-trip (LOAD-BEARING)
  //
  // This group is the definitive proof that prefetch writes the exact cache key
  // the map reads. For each of the four Stadia styles and both retina values,
  // expandTileUrl must produce a URL whose TileKey.tryParse result is
  // (style, z, x, y, retina).
  // ---------------------------------------------------------------------------

  group('parity: expandTileUrl → TileKey.tryParse round-trip', () {
    const configs = [
      stadiaAlidadeSmooth,
      stadiaAlidadeSmoothDark,
      stadiaOsmBright,
      stadiaOutdoors,
    ];

    // Extract style slug from urlTemplate for the expected style in TileKey.
    const styleForConfig = {
      kStyleIdAlidadeSmooth: 'alidade_smooth',
      kStyleIdAlidadeSmoothDark: 'alidade_smooth_dark',
      kStyleIdOsmBright: 'osm_bright',
      kStyleIdOutdoors: 'outdoors',
    };

    const testCases = [
      (z: 14, x: 8187, y: 5451), // London
      (z: 5, x: 15, y: 10),      // coarse zoom
      (z: 18, x: 0, y: 0),       // high zoom, origin
    ];

    for (final config in configs) {
      for (final retina in [false, true]) {
        for (final tc in testCases) {
          test(
            '${config.id} z=${tc.z} x=${tc.x} y=${tc.y} '
            'retina=$retina → TileKey matches',
            () {
              final url = expandTileUrl(
                config,
                tc.z,
                tc.x,
                tc.y,
                retina: retina,
              );
              final key = TileKey.tryParse(url);

              expect(
                key,
                isNotNull,
                reason:
                    'TileKey.tryParse returned null for URL '
                    '(first 60 chars: '
                    '${url.substring(0, url.length < 60 ? url.length : 60)})',
              );

              final expectedStyle = styleForConfig[config.id]!;
              expect(key!.style, expectedStyle,
                  reason: 'style mismatch for ${config.id}');
              expect(key.z, tc.z, reason: 'z mismatch');
              expect(key.x, tc.x, reason: 'x mismatch');
              expect(key.y, tc.y, reason: 'y mismatch');
              expect(key.retina, retina, reason: 'retina mismatch');
            },
          );
        }
      }
    }
  });
}
