/// Riverpod provider for the map-tile HTTP client.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/retry.dart';

/// The [http.Client] used by the map's tile provider.
///
/// Overridden in `main()` with the result of `createTileHttpClient()` so the
/// certificate-pinned client used in release builds is constructed once at
/// startup (its CA-bundle load is asynchronous). The default factory below is a
/// plain retrying client with system trust roots — used only in tests or when
/// no override is supplied; production always overrides it.
final tileHttpClientProvider = Provider<http.Client>((ref) {
  final client = RetryClient(http.Client());
  ref.onDispose(client.close);
  return client;
});
