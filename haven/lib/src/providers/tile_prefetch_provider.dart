/// Riverpod provider for the tile prefetch service (M-D).
///
/// Provides a [TilePrefetchService] singleton backed by the app's shared
/// encrypted `MapCachingProvider` and TLS-pinned `http.Client`. Both
/// dependencies are injected via providers so tests can substitute fakes
/// without touching Rust or the network.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/tile_cache_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:haven/src/services/tile_prefetch_service.dart';

/// The [TilePrefetchService] singleton for the lifetime of the app.
///
/// Reads [tileCachingProviderProvider] (the encrypted SQLCipher tile cache)
/// and [tileHttpClientProvider] (the TLS-pinned HTTP client). Both are
/// overridable in tests via `ProviderScope`.
///
/// `ref.onDispose` cancels any in-flight burst when the provider scope is
/// torn down (e.g. during tests or logout).
final tilePrefetchServiceProvider = Provider<TilePrefetchService>((ref) {
  final service = TilePrefetchServiceImpl(
    cachingProvider: ref.watch(tileCachingProviderProvider),
    httpClient: ref.watch(tileHttpClientProvider),
  );
  ref.onDispose(service.cancel);
  return service;
});
