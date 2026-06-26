/// Pure-Dart Web Mercator tile coordinate utilities for the anticipatory
/// prefetch pipeline (M-D).
///
/// No Flutter dependencies — only `dart:math`, `latlong2`, and
/// `TileProviderConfig`. Testable in plain Dart unit tests with no widget
/// harness or Rust bridge.
///
/// ## Privacy note
///
/// These functions produce `(z, x, y)` tuples that, at high zoom levels, pin
/// a member's location to within ~1 km. Callers must:
/// - never log the raw tuples,
/// - never persist them outside the encrypted tile cache,
/// - pass them only to `expandTileUrl` and then immediately to the
///   cache/HTTP layer.
library;

import 'dart:math' as math;

import 'package:haven/src/constants/tiles.dart';
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// latLngToTile
// ---------------------------------------------------------------------------

/// Converts a [LatLng] to the Web Mercator tile column/row at zoom [z].
///
/// Latitude is clamped to ±85.05112878° (the valid Web Mercator range)
/// before conversion so polar coordinates never produce negative or
/// out-of-range tile indices.
///
/// The returned `(x, y)` are always in `[0, 2^z − 1]`.
({int x, int y}) latLngToTile(LatLng p, int z) {
  final n = math.pow(2, z).toDouble();

  // Clamp latitude to avoid log(0) / negative values at the poles.
  final lat = p.latitude.clamp(-85.05112878, 85.05112878);
  final latRad = lat * math.pi / 180.0;

  final x = ((p.longitude + 180.0) / 360.0 * n).floor();
  final y = ((1.0 -
              math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) /
                  math.pi) /
          2.0 *
          n)
      .floor();

  final maxIdx = (1 << z) - 1;
  return (x: x.clamp(0, maxIdx), y: y.clamp(0, maxIdx));
}

// ---------------------------------------------------------------------------
// tileRing
// ---------------------------------------------------------------------------

/// Returns the set of tiles in the axis-aligned `(2r+1)²` block centred on
/// [center] at zoom [z].
///
/// All out-of-range indices are clamped to `[0, 2^z − 1]` and duplicates
/// (which can arise at the edges) are removed before returning.
///
/// `radius = 0` → the single center tile.
/// `radius = 1` → up to 9 tiles.
List<({int x, int y})> tileRing(
  ({int x, int y}) center,
  int z, {
  int radius = 1,
}) {
  final maxIdx = (1 << z) - 1;
  final seen = <int>{};
  final result = <({int x, int y})>[];

  for (var dx = -radius; dx <= radius; dx++) {
    for (var dy = -radius; dy <= radius; dy++) {
      final tx = (center.x + dx).clamp(0, maxIdx);
      final ty = (center.y + dy).clamp(0, maxIdx);
      // Encode as a single integer to dedupe clamped duplicates.
      final key = tx * (maxIdx + 1) + ty;
      if (seen.add(key)) {
        result.add((x: tx, y: ty));
      }
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// coarseParent
// ---------------------------------------------------------------------------

/// Returns the parent tile at zoom `z − delta` that contains tile
/// `(z, x, y)`.
///
/// [delta] is bit-shifted from the original coordinates: `(x >> delta,
/// y >> delta)`. The zoom level is floored at 0 so negative zooms are never
/// produced.
///
/// Used to prefetch one coarse-resolution parent that flutter_map up-samples
/// while the detail tiles load — the only additional zoom level prefetched.
({int z, int x, int y}) coarseParent(int z, int x, int y, int delta) {
  final pz = math.max(0, z - delta);
  final actualDelta = z - pz; // may be less than delta if z < delta
  return (z: pz, x: x >> actualDelta, y: y >> actualDelta);
}

// ---------------------------------------------------------------------------
// expandTileUrl
// ---------------------------------------------------------------------------

/// Expands a flutter_map URL template into a concrete tile URL.
///
/// Replicates flutter_map's `generateReplacementMap` token substitution:
/// - `{z}` → [z] as a string
/// - `{x}` → [x] as a string
/// - `{y}` → [y] as a string
/// - `{r}` → `@2x` if [retina] is true, otherwise the empty string
/// - Every key in `config.additionalOptions` (e.g. `{api_key}`) is replaced
///   by its value.
///
/// The produced URL, when parsed by `TileKey.tryParse`, yields exactly
/// `(style, z, x, y, retina)` — this is the load-bearing "prefetch writes
/// the same cache key the map reads" contract, verified by the parity tests
/// in `test/utils/tile_coordinates_test.dart`.
///
/// **Never log the returned URL**: it contains the Stadia `api_key`.
String expandTileUrl(
  TileProviderConfig config,
  int z,
  int x,
  int y, {
  required bool retina,
}) {
  var url = config.urlTemplate;

  // Replace tile coordinate tokens first.
  url = url
      .replaceAll('{z}', z.toString())
      .replaceAll('{x}', x.toString())
      .replaceAll('{y}', y.toString())
      .replaceAll('{r}', retina ? '@2x' : '');

  // Replace every additionalOptions token (e.g. {api_key}).
  for (final entry in config.additionalOptions.entries) {
    url = url.replaceAll('{${entry.key}}', entry.value);
  }

  return url;
}
