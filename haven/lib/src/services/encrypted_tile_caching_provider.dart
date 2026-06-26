/// flutter_map `MapCachingProvider` backed by Haven's SQLCipher tile cache.
///
/// Replaces flutter_map's built-in plaintext file cache with an encrypted
/// SQLCipher database managed by the Rust core. The Dart side is a thin
/// adapter: it parses the tile URL into a coordinate key (stripping the
/// api_key), calls [TileCacheStore] for get/put/putMetadata, and converts
/// flutter_map's `CachedMapTileMetadata` to/from Unix millisecond timestamps.
///
/// ## Fail-open design
///
/// Both `getTile` and `putTile` are wrapped in broad `on Object catch`
/// handlers:
/// - `getTile` returns `null` on any error → flutter_map falls back to a
///   network fetch, so a cache miss is always recoverable.
/// - `putTile` swallows all errors → it is called fire-and-forget by
///   flutter_map (not awaited), so throwing would be lost anyway; explicit
///   swallowing makes the intent clear.
///
/// Error logs include only `e.runtimeType`, never raw messages or URLs
/// (which may carry the api_key or internal details).
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:haven/src/services/tile_cache_store.dart';
import 'package:haven/src/services/tile_key.dart';

/// An encrypted `MapCachingProvider` backed by a [TileCacheStore].
///
/// Pass a `FfiTileCacheStore` in production; inject a fake in tests.
class EncryptedTileCachingProvider implements MapCachingProvider {
  /// Creates an [EncryptedTileCachingProvider].
  ///
  /// [isEnabled] defaults to `true`; pass `false` when the Rust cache failed
  /// to initialise so flutter_map falls back to live-only tile fetching.
  const EncryptedTileCachingProvider({
    required TileCacheStore store,
    bool isEnabled = true,
  })  : _store = store,
        _isEnabled = isEnabled;

  final TileCacheStore _store;
  final bool _isEnabled;

  // ---------------------------------------------------------------------------
  // MapCachingProvider contract
  // ---------------------------------------------------------------------------

  /// Whether this provider is active.
  ///
  /// When `false`, flutter_map will not call `getTile` or `putTile` and will
  /// fetch all tiles from the network. Never throws.
  @override
  bool get isSupported => _isEnabled;

  /// Retrieves a tile from the encrypted cache, or `null` on miss / error.
  ///
  /// Returns `null` (fail-open) on:
  /// - An unparseable or unrecognised URL (e.g. the dev OSM fallback).
  /// - Any internal store error.
  ///
  /// Never throws. Never logs the raw URL.
  @override
  Future<CachedMapTile?> getTile(String url) async {
    try {
      final key = TileKey.tryParse(url);
      if (key == null) return null;

      final data = await _store.get(
        style: key.style,
        z: key.z,
        x: key.x,
        y: key.y,
        retina: key.retina,
      );
      if (data == null) return null;

      final metadata = CachedMapTileMetadata(
        staleAt: DateTime.fromMillisecondsSinceEpoch(
          data.staleAtMs,
          isUtc: true,
        ),
        lastModified: data.lastModifiedMs != null
            ? DateTime.fromMillisecondsSinceEpoch(
                data.lastModifiedMs!,
                isUtc: true,
              )
            : null,
        etag: data.etag,
      );
      return (bytes: data.bytes, metadata: metadata);
    } on Object catch (e) {
      debugPrint('[EncryptedTileCache] getTile error: ${e.runtimeType}');
      return null;
    }
  }

  /// Inserts or updates a tile in the encrypted cache.
  ///
  /// Called fire-and-forget by flutter_map — this method must not throw.
  /// All errors are swallowed after a debug log.
  ///
  /// - `bytes == null` → HTTP 304 revalidation: only metadata is updated via
  ///   `TileCacheStore.putMetadata`.
  /// - `bytes != null` → HTTP 200 response: tile bytes + metadata are written
  ///   via `TileCacheStore.put`.
  ///
  /// Never logs the raw URL.
  @override
  Future<void> putTile({
    required String url,
    required CachedMapTileMetadata metadata,
    Uint8List? bytes,
  }) async {
    try {
      final key = TileKey.tryParse(url);
      if (key == null) return;

      final staleAtMs = metadata.staleAt.millisecondsSinceEpoch;
      final lastModifiedMs = metadata.lastModified?.millisecondsSinceEpoch;
      final etag = metadata.etag;

      if (bytes == null) {
        // HTTP 304: refresh metadata only.
        await _store.putMetadata(
          style: key.style,
          z: key.z,
          x: key.x,
          y: key.y,
          retina: key.retina,
          staleAtMs: staleAtMs,
          lastModifiedMs: lastModifiedMs,
          etag: etag,
        );
      } else {
        // HTTP 200: write bytes + metadata.
        await _store.put(
          style: key.style,
          z: key.z,
          x: key.x,
          y: key.y,
          retina: key.retina,
          bytes: bytes,
          staleAtMs: staleAtMs,
          lastModifiedMs: lastModifiedMs,
          etag: etag,
        );
      }
    } on Object catch (e) {
      // Swallow: flutter_map doesn't await putTile, so a throw would be
      // silently lost. Explicit catch makes the intent clear.
      debugPrint('[EncryptedTileCache] putTile error: ${e.runtimeType}');
    }
  }
}
