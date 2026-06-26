/// Riverpod providers for the encrypted tile cache.
///
/// Exposes two override seams for testing:
/// - [tileCacheStoreProvider] — swap `FfiTileCacheStore` for an in-memory
///   fake.
/// - [tileCacheEnabledProvider] — set to `false` when `tileCacheInit` failed
///   at startup so the `EncryptedTileCachingProvider` advertises itself as
///   unsupported and flutter_map fetches all tiles live.
///
/// Both providers are overridden in `main()` before `runApp`. The
/// [tileCachingProviderProvider] is the single seam that both map call sites
/// read — neither `map_page.dart` nor `map_style_settings_page.dart` need to
/// know whether caching is enabled; they just watch this provider.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/services/encrypted_tile_caching_provider.dart';
import 'package:haven/src/services/tile_cache_store.dart';

/// Whether the encrypted tile cache was successfully initialised at startup.
///
/// Overridden in `main()` with the result of the `tileCacheInit` call:
/// `true` on success, `false` on any error.
///
/// **Defaults to `false`** — the cache is "not ready" until a successful
/// `tileCacheInit` flips it on. This keeps the flag honest: a harness that
/// pumps the app WITHOUT running `main()`'s init (e.g. an integration test
/// driving the real widget tree) gets a no-op cache, rather than an
/// `EncryptedTileCachingProvider` that advertises `isSupported == true` while
/// the Rust `tiles.db` global is uninitialised — which would make flutter_map
/// call `getTile`/`putTile` on every tile and flood the FFI with
/// "not initialized" errors. Unit tests that exercise caching override this
/// to `true` explicitly (see [tileCacheStoreProvider] for the fake store).
final tileCacheEnabledProvider = Provider<bool>((ref) => false);

/// The [TileCacheStore] in use for the lifetime of the app.
///
/// Defaults to `FfiTileCacheStore`, which delegates to the Rust FFI.
/// Override with an in-memory fake in unit tests to avoid crossing the FFI
/// boundary.
final tileCacheStoreProvider = Provider<TileCacheStore>((ref) {
  return const FfiTileCacheStore();
});

/// The [EncryptedTileCachingProvider] injected into flutter_map's tile layer.
///
/// Reads [tileCacheEnabledProvider] (the init-success flag) and
/// [tileCacheStoreProvider] (the storage adapter). Both are overridable, so
/// tests can exercise the provider with a fake store and a chosen enabled
/// state without touching Rust or SharedPreferences.
///
/// This is the single seam both map call sites read:
/// ```dart
/// cachingProvider: ref.watch(tileCachingProviderProvider),
/// ```
final tileCachingProviderProvider =
    Provider<EncryptedTileCachingProvider>((ref) {
  final store = ref.watch(tileCacheStoreProvider);
  final enabled = ref.watch(tileCacheEnabledProvider);
  return EncryptedTileCachingProvider(store: store, isEnabled: enabled);
});
