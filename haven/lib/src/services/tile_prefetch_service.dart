/// Anticipatory tile prefetch service for the M-D milestone.
///
/// When a circle is selected and member locations arrive, this service warms a
/// frugal, privacy-preserving set of tiles around the members the user is most
/// likely to view next. Tiles are written to the encrypted `MapCachingProvider`
/// via the same cache key that flutter_map's `NetworkTileProvider` reads, so
/// the first render is a cache hit.
///
/// ## Privacy constraints
///
/// - Never logs raw coordinates or URLs (only counts and `runtimeType`).
/// - Skips the burst entirely when no API key is configured (dev builds with
///   `STADIA_API_KEY_PLACEHOLDER`).
/// - Cancels on circle-switch, app-background, logout, and dispose.
/// - Uses the app's shared pinned `http.Client` so prefetch requests are
///   indistinguishable from live tile fetches.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:haven/src/constants/tile_prefetch_policy.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/utils/tile_coordinates.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Contract for the anticipatory tile prefetch service.
///
/// `prefetch` warms tiles around `points` (already scoped to the most
/// likely-viewed member(s) by the caller). `cancel` aborts any in-flight
/// burst.
abstract interface class TilePrefetchService {
  /// Prefetches a frugal set of tiles around [points] at [landingZoom].
  ///
  /// - [points] — member coordinates, already prioritised by the caller
  ///   (nearest-to-camera first); the service caps the burst at
  ///   [kPrefetchMaxTilesTotal].
  /// - [config] — active `TileProviderConfig`; used for URL generation and
  ///   the `apiKeyConfigured` guard.
  /// - [landingZoom] — the zoom the user will land on when viewing a member.
  /// - [retina] — whether to fetch @2x tiles (passed from `RetinaMode`).
  ///
  /// A new call supersedes any in-flight burst from a previous call.
  ///
  /// Never throws — all errors are caught and logged (type-only, no raw
  /// messages or coordinates) so the prefetch is always a best-effort hint.
  Future<void> prefetch({
    required List<LatLng> points,
    required TileProviderConfig config,
    required int landingZoom,
    required bool retina,
  });

  /// Cancels any in-flight burst immediately.
  ///
  /// Safe to call repeatedly or before any [prefetch] has been issued.
  void cancel();
}

/// Production implementation of [TilePrefetchService].
///
/// Inject `cachingProvider` (the same `EncryptedTileCachingProvider` that
/// the map's `NetworkTileProvider` uses) and `httpClient` (the app's shared
/// TLS-pinned client) so prefetch writes exactly the keys the map reads and
/// requests are indistinguishable from live tile fetches.
class TilePrefetchServiceImpl implements TilePrefetchService {
  /// Creates a [TilePrefetchServiceImpl].
  TilePrefetchServiceImpl({
    required MapCachingProvider cachingProvider,
    required http.Client httpClient,
  })  : _cachingProvider = cachingProvider,
        _httpClient = httpClient;

  final MapCachingProvider _cachingProvider;
  final http.Client _httpClient;

  /// Generation token. Incremented by both [cancel] and [prefetch].
  ///
  /// Each [prefetch] call captures its generation at entry; the burst checks
  /// that its generation still matches before each network operation. A
  /// superseding [prefetch] or a [cancel] both increment the counter, so any
  /// prior burst's captured generation goes stale and it exits cooperatively.
  int _generation = 0;

  @override
  void cancel() {
    _generation++;
  }

  @override
  Future<void> prefetch({
    required List<LatLng> points,
    required TileProviderConfig config,
    required int landingZoom,
    required bool retina,
  }) async {
    // Advance the generation: supersedes any prior in-flight burst AND
    // prevents a concurrent cancel() from racing us back to the same token.
    final myGen = ++_generation;

    // Guard: no API key → no network (dev builds would hit OSM or 403s).
    if (!config.apiKeyConfigured || points.isEmpty) return;

    // Build the deduplicated tile set.
    final tiles = _buildTileSet(points, landingZoom, config);

    if (tiles.isEmpty) return;

    debugPrint(
      '[TilePrefetch] Starting burst: ${tiles.length} tile(s) for '
      '${points.length} point(s)',
    );

    // Process with bounded concurrency.
    await _runBurst(tiles, config, retina, myGen);
  }

  // ---------------------------------------------------------------------------
  // Tile set construction
  // ---------------------------------------------------------------------------

  List<_TileCoord> _buildTileSet(
    List<LatLng> points,
    int landingZoom,
    TileProviderConfig config,
  ) {
    final maxZ = config.maxNativeZoom;
    final z = landingZoom.clamp(3, maxZ);

    // Union of all ring tiles, preserving insertion order (nearest-member tiles
    // first, so truncation at kPrefetchMaxTilesTotal drops the furthest).
    final seen = <_TileKey>{};
    final result = <_TileCoord>[];

    void addTile(int tz, int tx, int ty) {
      final key = _TileKey(tz, tx, ty);
      if (seen.add(key)) {
        result.add(_TileCoord(tz, tx, ty));
      }
    }

    for (final point in points) {
      if (result.length >= kPrefetchMaxTilesTotal) break;

      final center = latLngToTile(point, z);
      // kPrefetchRing == 1 == the tileRing default; named here for clarity.
      // ignore: avoid_redundant_argument_values
      final ring = tileRing(center, z, radius: kPrefetchRing);
      for (final t in ring) {
        if (result.length >= kPrefetchMaxTilesTotal) break;
        addTile(z, t.x, t.y);
      }

      // One coarse parent per member (the tile flutter_map up-samples during
      // the loading flash — a genuinely-rendered tile, not dead weight).
      if (result.length < kPrefetchMaxTilesTotal) {
        final parent = coarseParent(
          z,
          center.x,
          center.y,
          kPrefetchCoarseParentDelta,
        );
        addTile(parent.z, parent.x, parent.y);
      }
    }

    // Log when the cap truncated the intended set.
    if (result.length >= kPrefetchMaxTilesTotal) {
      debugPrint(
        '[TilePrefetch] capped at $kPrefetchMaxTilesTotal tiles',
      );
    }

    return result.take(kPrefetchMaxTilesTotal).toList();
  }

  // ---------------------------------------------------------------------------
  // Burst execution
  // ---------------------------------------------------------------------------

  Future<void> _runBurst(
    List<_TileCoord> tiles,
    TileProviderConfig config,
    bool retina,
    int myGen,
  ) async {
    var i = 0;
    // Process in windows of kPrefetchConcurrency.
    while (i < tiles.length) {
      if (myGen != _generation) {
        debugPrint(
          '[TilePrefetch] Cancelled '
          '(${tiles.length - i} tile(s) remaining)',
        );
        return;
      }

      final batch = tiles.skip(i).take(kPrefetchConcurrency).toList();
      // Run the batch concurrently, but propagate 429-halt via the return
      // value.
      final halt = await _processBatch(batch, config, retina, myGen);
      if (halt) {
        debugPrint('[TilePrefetch] 429 — burst halted');
        return;
      }
      i += batch.length;
    }

    debugPrint('[TilePrefetch] Burst complete (${tiles.length} tile(s))');
  }

  /// Processes one batch concurrently.
  ///
  /// Returns `true` if the burst should halt (HTTP 429 received).
  Future<bool> _processBatch(
    List<_TileCoord> batch,
    TileProviderConfig config,
    bool retina,
    int myGen,
  ) async {
    var halt = false;

    await Future.wait(
      batch.map((tile) async {
        if (myGen != _generation || halt) return;
        final shouldHalt = await _fetchOne(tile, config, retina, myGen);
        if (shouldHalt) halt = true;
      }),
    );

    return halt;
  }

  /// Fetches and caches a single tile.
  ///
  /// Returns `true` if a 429 was received and the burst should halt.
  Future<bool> _fetchOne(
    _TileCoord tile,
    TileProviderConfig config,
    bool retina,
    int myGen,
  ) async {
    if (myGen != _generation) return false;

    final url = expandTileUrl(config, tile.z, tile.x, tile.y, retina: retina);

    // Dedupe: skip tiles already in cache that are not stale.
    try {
      final cached = await _cachingProvider.getTile(url);
      if (cached != null && !cached.metadata.isStale) {
        return false; // already warm
      }
    } on Object catch (e) {
      // getTile errors are non-fatal: proceed to fetch.
      debugPrint('[TilePrefetch] getTile check error: ${e.runtimeType}');
    }

    if (myGen != _generation) return false;

    // Fetch the tile.
    final headers = <String, String>{
      if (config.userAgentHeader != null)
        'User-Agent': config.userAgentHeader!,
    };

    try {
      final response =
          await _httpClient.get(Uri.parse(url), headers: headers);

      if (myGen != _generation) return false;

      if (response.statusCode == 200) {
        final metadata = CachedMapTileMetadata.fromHttpHeaders(
          response.headers,
        );
        await _cachingProvider.putTile(
          url: url,
          metadata: metadata,
          bytes: response.bodyBytes,
        );
        return false;
      } else if (response.statusCode == 429) {
        // Honour Retry-After if present, else apply a flat backoff delay.
        final retryAfter = _parseRetryAfter(response.headers);
        if (retryAfter != null) {
          await Future<void>.delayed(retryAfter);
        } else {
          // Flat backoff delay before halting the burst.
          await Future<void>.delayed(kPrefetchBackoffBase);
        }
        return true; // halt the whole burst
      }
      // Other non-200 responses: soft-skip (log status code only).
      debugPrint(
        '[TilePrefetch] Non-200 response: ${response.statusCode}',
      );
    } on SocketException catch (e) {
      debugPrint(
        '[TilePrefetch] SocketException: ${e.runtimeType} '
        '— offline, skipping',
      );
    } on http.ClientException catch (e) {
      debugPrint(
        '[TilePrefetch] ClientException: ${e.runtimeType} — skipping',
      );
    } on Object catch (e) {
      debugPrint(
        '[TilePrefetch] Fetch error: ${e.runtimeType} — skipping',
      );
    }

    return false;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Parses the `Retry-After` header as a [Duration], or returns `null`.
  Duration? _parseRetryAfter(Map<String, String> headers) {
    final raw = headers['retry-after'];
    if (raw == null) return null;
    final secs = int.tryParse(raw.trim());
    if (secs != null && secs > 0) return Duration(seconds: secs);
    return null;
  }
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

/// A tile coordinate triple — used only inside this library.
class _TileCoord {
  const _TileCoord(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;
}

/// Value-equality key for deduplication.
@immutable
class _TileKey {
  const _TileKey(this.z, this.x, this.y);
  final int z;
  final int x;
  final int y;

  @override
  bool operator ==(Object other) =>
      other is _TileKey && z == other.z && x == other.x && y == other.y;

  @override
  int get hashCode => Object.hash(z, x, y);
}
