/// Tests for [EncryptedTileCachingProvider].
///
/// Uses an in-memory `FakeTileCacheStore` — no FFI, no Rust bridge, no
/// network.
///
/// Verifies the flutter_map `MapCachingProvider` contract:
/// - `getTile` returns correct `CachedMapTile` on hit (UTC timestamp
///   round-trip, etag pass-through).
/// - `getTile` returns null on miss.
/// - `getTile` returns null (fail-open) when the store throws.
/// - `getTile` returns null for unrecognised URLs without calling the store.
/// - `putTile` with bytes → `TileCacheStore.put` (never `putMetadata`).
/// - `putTile` with null bytes → `TileCacheStore.putMetadata` (never `put`).
/// - `putTile` when store throws → completes normally (error swallowed).
/// - The store is NEVER called with anything containing "api_key".
/// - `isSupported` matches the `isEnabled` constructor parameter.
library;

import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/encrypted_tile_caching_provider.dart';
import 'package:haven/src/services/tile_cache_store.dart';

// ---------------------------------------------------------------------------
// Fake store
// ---------------------------------------------------------------------------

/// Records every call and lets the test configure canned return values.
class FakeTileCacheStore implements TileCacheStore {
  /// If set, [get] returns this value (null = cache miss).
  CachedTileData? getResult;

  /// If set to true, [get] throws [_StoreException].
  bool throwOnGet = false;

  /// If set to true, [put] throws [_StoreException].
  bool throwOnPut = false;

  /// If set to true, [putMetadata] throws [_StoreException].
  bool throwOnPutMetadata = false;

  /// Log of every [get] call as `'get:style/z/x/y/retina'`.
  final List<String> getCalls = [];

  /// Log of every [put] call.
  final List<Map<String, Object?>> putCalls = [];

  /// Log of every [putMetadata] call.
  final List<Map<String, Object?>> putMetadataCalls = [];

  @override
  Future<CachedTileData?> get({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
  }) async {
    getCalls.add('$style/$z/$x/$y/$retina');
    if (throwOnGet) throw const _StoreException('get failed');
    return getResult;
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
  }) async {
    putCalls.add({
      'style': style,
      'z': z,
      'x': x,
      'y': y,
      'retina': retina,
      'bytes': bytes,
      'staleAtMs': staleAtMs,
      'lastModifiedMs': lastModifiedMs,
      'etag': etag,
    });
    if (throwOnPut) throw const _StoreException('put failed');
  }

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
  }) async {
    putMetadataCalls.add({
      'style': style,
      'z': z,
      'x': x,
      'y': y,
      'retina': retina,
      'staleAtMs': staleAtMs,
      'lastModifiedMs': lastModifiedMs,
      'etag': etag,
    });
    if (throwOnPutMetadata) throw const _StoreException('putMetadata failed');
  }

  @override
  Future<int> evict({
    required int maxBytes,
    required int idleAgeSecs,
    required int maxRetentionSecs,
  }) async =>
      0;
}

class _StoreException implements Exception {
  const _StoreException(this.message);
  final String message;
  @override
  String toString() => '_StoreException($message)';
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A valid Stadia tile URL (non-retina, alidade_smooth, with an api_key).
const _kStadiaUrl =
    'https://tiles.stadiamaps.com/tiles/alidade_smooth/14/8187/5451.png'
    '?api_key=SUPERSECRET';

/// A valid Stadia tile URL (retina, alidade_smooth).
const _kStadiaUrlRetina =
    'https://tiles.stadiamaps.com/tiles/alidade_smooth/14/8187/5451@2x.png'
    '?api_key=SUPERSECRET';

/// An unrecognised URL (dev OSM fallback — must never be cached).
const _kOsmUrl = 'https://tile.openstreetmap.org/10/512/384.png';

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('EncryptedTileCachingProvider', () {
    // -----------------------------------------------------------------------
    // isSupported
    // -----------------------------------------------------------------------

    group('isSupported', () {
      test('returns true when isEnabled is true (default)', () {
        final provider = EncryptedTileCachingProvider(
          store: FakeTileCacheStore(),
        );
        expect(provider.isSupported, isTrue);
      });

      test('returns false when isEnabled is false', () {
        final provider = EncryptedTileCachingProvider(
          store: FakeTileCacheStore(),
          isEnabled: false,
        );
        expect(provider.isSupported, isFalse);
      });
    });

    // -----------------------------------------------------------------------
    // getTile
    // -----------------------------------------------------------------------

    group('getTile', () {
      test('returns correct CachedMapTile on hit', () async {
        final bytes = Uint8List.fromList([1, 2, 3, 4]);
        // 2024-01-15 12:00:00 UTC
        final staleAt = DateTime.utc(2024, 1, 15, 12);
        // 2024-01-10 08:00:00 UTC
        final lastModified = DateTime.utc(2024, 1, 10, 8);
        const etag = '"abc123"';

        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: bytes,
            staleAtMs: staleAt.millisecondsSinceEpoch,
            lastModifiedMs: lastModified.millisecondsSinceEpoch,
            etag: etag,
          );

        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile(_kStadiaUrl);

        expect(result, isNotNull);
        expect(result!.bytes, equals(bytes));
        expect(result.metadata.staleAt, equals(staleAt));
        expect(result.metadata.lastModified, equals(lastModified));
        expect(result.metadata.etag, equals(etag));
        // Timestamps must round-trip as UTC.
        expect(result.metadata.staleAt.isUtc, isTrue);
        expect(result.metadata.lastModified!.isUtc, isTrue);
      });

      test('staleAt and lastModified are UTC', () async {
        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: Uint8List.fromList([0]),
            staleAtMs: 1_700_000_000_000, // some ms epoch
            lastModifiedMs: 1_699_000_000_000,
          );
        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile(_kStadiaUrl);
        expect(result!.metadata.staleAt.isUtc, isTrue);
        expect(result.metadata.lastModified!.isUtc, isTrue);
      });

      test('returns null when lastModifiedMs is null', () async {
        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: Uint8List.fromList([0]),
            staleAtMs: 1_700_000_000_000,
          );
        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile(_kStadiaUrl);
        expect(result, isNotNull);
        expect(result!.metadata.lastModified, isNull);
        expect(result.metadata.etag, isNull);
      });

      test('returns null on cache miss (store returns null)', () async {
        final store = FakeTileCacheStore()..getResult = null;
        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile(_kStadiaUrl);
        expect(result, isNull);
        expect(store.getCalls, hasLength(1));
      });

      test('returns null (fail-open) when store throws', () async {
        final store = FakeTileCacheStore()..throwOnGet = true;
        final provider = EncryptedTileCachingProvider(store: store);
        // Must not throw — fail-open.
        final result = await provider.getTile(_kStadiaUrl);
        expect(result, isNull);
      });

      test('returns null for unrecognised URL, store never called', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile(_kOsmUrl);
        expect(result, isNull);
        expect(store.getCalls, isEmpty);
      });

      test('returns null for garbage URL, store never called', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);
        final result = await provider.getTile('not a url');
        expect(result, isNull);
        expect(store.getCalls, isEmpty);
      });

      test('store is never called with anything containing api_key', () async {
        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: Uint8List.fromList([1]),
            staleAtMs: 1_700_000_000_000,
          );
        final provider = EncryptedTileCachingProvider(store: store);
        await provider.getTile(_kStadiaUrl);

        // The only argument that could carry the key is 'style'.
        for (final call in store.getCalls) {
          expect(call, isNot(contains('api_key')));
          expect(call, isNot(contains('SUPERSECRET')));
        }
      });

      test('retina URL passes retina=true to store', () async {
        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: Uint8List.fromList([9]),
            staleAtMs: 1_700_000_000_000,
          );
        final provider = EncryptedTileCachingProvider(store: store);
        await provider.getTile(_kStadiaUrlRetina);
        // The getCalls entry should end with '/true' (retina=true).
        expect(store.getCalls, hasLength(1));
        expect(store.getCalls.first, endsWith('/true'));
      });

      test('non-retina URL passes retina=false to store', () async {
        final store = FakeTileCacheStore()
          ..getResult = CachedTileData(
            bytes: Uint8List.fromList([9]),
            staleAtMs: 1_700_000_000_000,
          );
        final provider = EncryptedTileCachingProvider(store: store);
        await provider.getTile(_kStadiaUrl);
        expect(store.getCalls, hasLength(1));
        expect(store.getCalls.first, endsWith('/false'));
      });
    });

    // -----------------------------------------------------------------------
    // putTile
    // -----------------------------------------------------------------------

    group('putTile', () {
      // March 1 — month=3 is explicit; day=1 is the default but is kept here
      // for date clarity.
      // ignore: avoid_redundant_argument_values
      final staleAt = DateTime.utc(2024, 3, 1);
      final lastModified = DateTime.utc(2024, 2, 28, 12);
      const etag = '"etag-xyz"';

      /// Builds metadata with explicitly controlled nullable fields.
      ///
      /// [includeLastModified] controls whether [lastModified] is populated;
      /// unlike a default-parameter helper, this avoids the `?? fallback`
      /// pitfall when the test wants to assert a null field.
      CachedMapTileMetadata meta({
        bool includeLastModified = true,
        bool includeEtag = true,
      }) =>
          CachedMapTileMetadata(
            staleAt: staleAt,
            lastModified: includeLastModified ? lastModified : null,
            etag: includeEtag ? etag : null,
          );

      test('with bytes → calls put (not putMetadata)', () async {
        final bytes = Uint8List.fromList([10, 20, 30]);
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kStadiaUrl,
          metadata: meta(),
          bytes: bytes,
        );

        expect(store.putCalls, hasLength(1));
        expect(store.putMetadataCalls, isEmpty);

        final call = store.putCalls.first;
        expect(call['style'], 'alidade_smooth');
        expect(call['z'], 14);
        expect(call['x'], 8187);
        expect(call['y'], 5451);
        expect(call['retina'], isFalse);
        expect(call['bytes'], equals(bytes));
        expect(call['staleAtMs'], staleAt.millisecondsSinceEpoch);
        expect(call['lastModifiedMs'], lastModified.millisecondsSinceEpoch);
        expect(call['etag'], etag);
      });

      test('with null bytes → calls putMetadata (not put)', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kStadiaUrl,
          metadata: meta(),
        );

        expect(store.putMetadataCalls, hasLength(1));
        expect(store.putCalls, isEmpty);

        final call = store.putMetadataCalls.first;
        expect(call['style'], 'alidade_smooth');
        expect(call['z'], 14);
        expect(call['x'], 8187);
        expect(call['y'], 5451);
        expect(call['retina'], isFalse);
        expect(call['staleAtMs'], staleAt.millisecondsSinceEpoch);
        expect(call['lastModifiedMs'], lastModified.millisecondsSinceEpoch);
        expect(call['etag'], etag);
      });

      test('with null bytes and null lastModified → putMetadata with null ms',
          () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kStadiaUrl,
          metadata: meta(includeLastModified: false, includeEtag: false),
        );

        expect(store.putMetadataCalls, hasLength(1));
        final call = store.putMetadataCalls.first;
        expect(call['lastModifiedMs'], isNull);
        expect(call['etag'], isNull);
      });

      test('completes normally when store.put throws (error swallowed)',
          () async {
        final store = FakeTileCacheStore()..throwOnPut = true;
        final provider = EncryptedTileCachingProvider(store: store);

        // Must not throw.
        await expectLater(
          provider.putTile(
            url: _kStadiaUrl,
            metadata: meta(),
            bytes: Uint8List.fromList([1]),
          ),
          completes,
        );
      });

      test(
          'completes normally when store.putMetadata throws (error swallowed)',
          () async {
        final store = FakeTileCacheStore()..throwOnPutMetadata = true;
        final provider = EncryptedTileCachingProvider(store: store);

        await expectLater(
          provider.putTile(
            url: _kStadiaUrl,
            metadata: meta(),
          ),
          completes,
        );
      });

      test('unrecognised URL → store never called', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kOsmUrl,
          metadata: meta(),
          bytes: Uint8List.fromList([1]),
        );

        expect(store.putCalls, isEmpty);
        expect(store.putMetadataCalls, isEmpty);
      });

      test('store is NEVER called with anything containing api_key', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kStadiaUrl,
          metadata: meta(),
          bytes: Uint8List.fromList([0xFF]),
        );

        for (final call in store.putCalls) {
          for (final value in call.values) {
            if (value is String) {
              expect(value, isNot(contains('api_key')));
              expect(value, isNot(contains('SUPERSECRET')));
            }
          }
        }
      });

      test('retina URL → put called with retina=true', () async {
        final store = FakeTileCacheStore();
        final provider = EncryptedTileCachingProvider(store: store);

        await provider.putTile(
          url: _kStadiaUrlRetina,
          metadata: meta(),
          bytes: Uint8List.fromList([1]),
        );

        expect(store.putCalls, hasLength(1));
        expect(store.putCalls.first['retina'], isTrue);
      });
    });
  });
}
