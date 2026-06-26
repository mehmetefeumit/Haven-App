/// Tests for [tileCachingProviderProvider].
///
/// Verifies that the provider returns an `EncryptedTileCachingProvider` whose
/// `isSupported` matches the [tileCacheEnabledProvider] override. Uses a fake
/// store so no Rust FFI or SharedPreferences is needed.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/tile_cache_provider.dart';
import 'package:haven/src/services/encrypted_tile_caching_provider.dart';
import 'package:haven/src/services/tile_cache_store.dart';

// ---------------------------------------------------------------------------
// Minimal fake store — the provider only reads [TileCacheStore]; the test
// never actually calls get/put/evict on it.
// ---------------------------------------------------------------------------

class _NoopStore implements TileCacheStore {
  const _NoopStore();

  @override
  Future<CachedTileData?> get({
    required String style,
    required int z,
    required int x,
    required int y,
    required bool retina,
  }) async =>
      null;

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
  }) async {}

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
  }) async {}

  @override
  Future<int> evict({
    required int maxBytes,
    required int idleAgeSecs,
    required int maxRetentionSecs,
  }) async =>
      0;
}

void main() {
  group('tileCachingProviderProvider', () {
    test(
      'returns EncryptedTileCachingProvider with isSupported=true when enabled',
      () {
        final container = ProviderContainer(
          overrides: [
            tileCacheStoreProvider.overrideWithValue(const _NoopStore()),
            tileCacheEnabledProvider.overrideWithValue(true),
          ],
        );
        addTearDown(container.dispose);

        final provider = container.read(tileCachingProviderProvider);

        expect(provider, isA<EncryptedTileCachingProvider>());
        expect(provider.isSupported, isTrue);
      },
    );

    test(
      'returns EncryptedTileCachingProvider with isSupported=false when '
      'disabled',
      () {
        final container = ProviderContainer(
          overrides: [
            tileCacheStoreProvider.overrideWithValue(const _NoopStore()),
            tileCacheEnabledProvider.overrideWithValue(false),
          ],
        );
        addTearDown(container.dispose);

        final provider = container.read(tileCachingProviderProvider);

        expect(provider, isA<EncryptedTileCachingProvider>());
        expect(provider.isSupported, isFalse);
      },
    );

    test('tileCacheEnabledProvider defaults to false (off until init)', () {
      final container = ProviderContainer(
        overrides: [
          // Provide a fake store so the FFI is not invoked, but leave
          // tileCacheEnabledProvider at its default.
          tileCacheStoreProvider.overrideWithValue(const _NoopStore()),
        ],
      );
      addTearDown(container.dispose);

      // The default is `false`: a harness that never runs main()'s
      // tileCacheInit gets a no-op cache (isSupported == false), so flutter_map
      // never calls the uninitialised FFI. main() overrides this to the init
      // result, so production caching still works.
      expect(container.read(tileCacheEnabledProvider), isFalse);
      expect(
        container.read(tileCachingProviderProvider).isSupported,
        isFalse,
      );
    });
  });
}
