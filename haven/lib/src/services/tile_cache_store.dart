/// Port/adapter layer between `EncryptedTileCachingProvider` and the Rust FFI.
///
/// Defining an interface here keeps the provider unit-testable: tests inject a
/// fake `TileCacheStore` (or any [TileCacheStore] implementation) without ever
/// crossing the FFI boundary or touching the Rust bridge.
library;

import 'dart:typed_data';

import 'package:haven/src/rust/api.dart'
    show tileCacheEvict, tileCacheGet, tileCachePut, tileCachePutMetadata;

/// A single tile entry returned by [TileCacheStore.get].
///
/// Mirrors `TileCacheEntryFfi` but uses plain Dart types (no `PlatformInt64`
/// alias leaks into callers that don't import the generated bindings).
class CachedTileData {
  /// Creates a cached tile entry.
  const CachedTileData({
    required this.bytes,
    required this.staleAtMs,
    this.lastModifiedMs,
    this.etag,
  });

  /// Raw tile bytes (PNG).
  final Uint8List bytes;

  /// HTTP freshness deadline as Unix milliseconds (UTC).
  final int staleAtMs;

  /// `Last-Modified` as Unix milliseconds (UTC), or `null` if absent.
  final int? lastModifiedMs;

  /// `ETag` value, or `null` if absent.
  final String? etag;
}

/// Abstraction over the SQLCipher tile-cache storage.
///
/// The FFI implementation is `FfiTileCacheStore`; test implementations may
/// substitute an in-memory fake without touching the Rust bridge.
abstract interface class TileCacheStore {
  /// Retrieves the cached tile for the given coordinates, or `null` on miss.
  Future<CachedTileData?> get({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
  });

  /// Inserts or replaces the tile's bytes and metadata (a 200-response write).
  Future<void> put({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  });

  /// Updates only the freshness metadata without touching bytes (a
  /// 304-response write).
  Future<void> putMetadata({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  });

  /// Evicts stale, over-retention, and over-budget tiles.
  ///
  /// Returns the number of rows deleted.
  Future<int> evict({
    required int maxBytes,
    required int idleAgeSecs,
    required int maxRetentionSecs,
  });
}

/// Production [TileCacheStore] that delegates to the generated Rust FFI.
///
/// All FFI functions accept `PlatformInt64` which is `int` on native
/// platforms, so plain `int` values pass through without conversion. The
/// return value of `tileCacheEvict` is `BigInt` on web (where
/// `PlatformInt64 = BigInt`), so this class converts it with
/// `BigInt.toInt` for a uniform `int` result.
class FfiTileCacheStore implements TileCacheStore {
  /// Creates an [FfiTileCacheStore].
  const FfiTileCacheStore();

  @override
  Future<CachedTileData?> get({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
  }) async {
    final entry = await tileCacheGet(
      style: style,
      z: z,
      x: x,
      y: y,
      retina: retina,
    );
    if (entry == null) return null;
    return CachedTileData(
      bytes: entry.bytes,
      staleAtMs: entry.staleAtMs,
      lastModifiedMs: entry.lastModifiedMs,
      etag: entry.etag,
    );
  }

  @override
  Future<void> put({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
    required Uint8List bytes,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  }) =>
      tileCachePut(
        style: style,
        z: z,
        x: x,
        y: y,
        retina: retina,
        bytes: bytes,
        staleAtMs: staleAtMs,
        lastModifiedMs: lastModifiedMs,
        etag: etag,
      );

  @override
  Future<void> putMetadata({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
    required int staleAtMs,
    int? lastModifiedMs,
    String? etag,
  }) =>
      tileCachePutMetadata(
        style: style,
        z: z,
        x: x,
        y: y,
        retina: retina,
        staleAtMs: staleAtMs,
        lastModifiedMs: lastModifiedMs,
        etag: etag,
      );

  @override
  Future<int> evict({
    required int maxBytes,
    required int idleAgeSecs,
    required int maxRetentionSecs,
  }) async {
    final deleted = await tileCacheEvict(
      maxBytes: maxBytes,
      idleAgeSecs: idleAgeSecs,
      maxRetentionSecs: maxRetentionSecs,
    );
    // On native, tileCacheEvict returns BigInt (the PlatformInt64 typedef
    // resolves to int on native, but the actual Dart function signature
    // says BigInt — convert to be safe across platforms).
    return deleted.toInt();
  }
}
