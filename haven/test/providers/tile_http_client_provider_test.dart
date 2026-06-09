import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:http/http.dart' as http;

void main() {
  group('tileHttpClientProvider', () {
    test('returns the overridden client (main() injects the pinned one)', () {
      final injected = http.Client();
      addTearDown(injected.close);
      final container = ProviderContainer(
        overrides: [tileHttpClientProvider.overrideWithValue(injected)],
      );
      addTearDown(container.dispose);

      expect(container.read(tileHttpClientProvider), same(injected));
    });

    test('has a usable default client when not overridden', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(tileHttpClientProvider), isA<http.Client>());
    });
  });
}
