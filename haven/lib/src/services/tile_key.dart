/// Parse Stadia Maps tile URLs into their coordinate components.
///
/// This is the load-bearing cache-key logic that strips the `api_key` query
/// parameter before any coordinate or style information reaches the storage
/// layer or logs.
library;

import 'package:flutter/foundation.dart';

/// The canonical set of Stadia basemap style slugs Haven uses.
///
/// Only these slugs appear in the Stadia URL path; any other style is treated
/// as unrecognised and returns a cache miss. This allowlist also enforces that
/// the dev OpenStreetMap fallback host is never cached.
const Set<String> _kKnownStyles = {
  'alidade_smooth',
  'alidade_smooth_dark',
  'osm_bright',
  'outdoors',
};

/// A parsed Stadia tile URL, suitable as a cache key.
///
/// [tryParse] strips the `api_key` query parameter and returns `null` for any
/// URL shape Haven doesn't recognise (dev OSM fallback, CDN paths, etc.) so
/// unrecognised URLs always pass through to the network without crashing.
///
/// **Never log a raw tile URL** — it may carry the `api_key`.
@immutable
class TileKey {
  /// Creates a parsed tile key.
  ///
  /// Prefer [tryParse] over direct construction.
  const TileKey({
    required this.style,
    required this.z,
    required this.x,
    required this.y,
    required this.retina,
  });

  /// Stadia basemap style slug (e.g. `alidade_smooth`).
  final String style;

  /// Zoom level.
  final int z;

  /// Tile column.
  final int x;

  /// Tile row.
  final int y;

  /// Whether this is a 2x (HiDPI) retina tile (`@2x.png` suffix).
  final bool retina;

  /// Parses a Stadia tile URL into a [TileKey], or returns `null`.
  ///
  /// Expected URL shape (query string stripped before parsing):
  /// ```plaintext
  /// https://tiles.stadiamaps.com/tiles/<style>/<z>/<x>/<y>{r}.png
  /// ```
  /// where `{r}` is `@2x` for retina tiles and empty otherwise.
  ///
  /// Returns `null` for:
  /// - Unparseable URLs.
  /// - The dev OpenStreetMap fallback host.
  /// - Any host other than `tiles.stadiamaps.com`.
  /// - Paths that don't match `/tiles/<style>/<z>/<x>/<y>(|@2x).png`.
  /// - Unknown style slugs.
  /// - Non-integer `z`, `x`, `y` segments.
  static TileKey? tryParse(String url) {
    // Drop the query string first so the api_key never enters path parsing.
    final qIdx = url.indexOf('?');
    final pathOnly = qIdx >= 0 ? url.substring(0, qIdx) : url;

    final uri = Uri.tryParse(pathOnly);
    if (uri == null) return null;

    // Only cache Stadia tiles.
    if (uri.host != 'tiles.stadiamaps.com') return null;

    // Path must be: /tiles/<style>/<z>/<x>/<file>
    // where <file> is `<y>.png` or `<y>@2x.png`.
    final segments = uri.pathSegments;
    // Expected: ['tiles', style, z, x, '<y>(|@2x).png']
    if (segments.length != 5) return null;
    if (segments[0] != 'tiles') return null;

    final style = segments[1];
    if (!_kKnownStyles.contains(style)) return null;

    final zVal = int.tryParse(segments[2]);
    final xVal = int.tryParse(segments[3]);
    if (zVal == null || xVal == null) return null;

    final file = segments[4];
    // Accept <y>.png and <y>@2x.png
    final bool retina;
    final String yStr;
    if (file.endsWith('@2x.png')) {
      retina = true;
      yStr = file.substring(0, file.length - '@2x.png'.length);
    } else if (file.endsWith('.png')) {
      retina = false;
      yStr = file.substring(0, file.length - '.png'.length);
    } else {
      return null;
    }

    final yVal = int.tryParse(yStr);
    if (yVal == null) return null;

    return TileKey(style: style, z: zVal, x: xVal, y: yVal, retina: retina);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TileKey &&
          style == other.style &&
          z == other.z &&
          x == other.x &&
          y == other.y &&
          retina == other.retina);

  @override
  int get hashCode => Object.hash(style, z, x, y, retina);

  /// Returns a redacted representation (no coordinates).
  ///
  /// `z`, `x`, and `y` are omitted from `toString` because at high zoom
  /// levels they approximate a member's location to within ~1 km. Use
  /// equality / hashCode for deduplication; never log the raw fields.
  @override
  String toString() => 'TileKey(style: $style, retina: $retina)';
}
