/// Tests for tile-provider configuration constants.
///
/// Verifies the values and invariants documented in
/// `lib/src/constants/tiles.dart`.  These tests deliberately do NOT import
/// flutter_map or any tile-loading logic; they are pure Dart assertions on
/// the constant values themselves so they run in the lightweight unit-test
/// environment with no platform channels.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';

void main() {
  group('defaultTileProvider', () {
    test('id is stadia_alidade_smooth', () {
      expect(defaultTileProvider.id, 'stadia_alidade_smooth');
    });

    test('urlTemplate contains tiles.stadiamaps.com', () {
      expect(
        defaultTileProvider.urlTemplate,
        contains('tiles.stadiamaps.com'),
      );
    });

    test('urlTemplate contains {r} retina-pixel token', () {
      expect(defaultTileProvider.urlTemplate, contains('{r}'));
    });

    test('urlTemplate contains ?api_key={api_key} query token', () {
      expect(
        defaultTileProvider.urlTemplate,
        contains('?api_key={api_key}'),
      );
    });

    // SECURITY / OSM compliance #17: The raw OSM endpoint must never be
    // the release default (OSMF tile-usage policy + CI guard).
    test(
      'SECURITY: urlTemplate does NOT point at tile.openstreetmap.org',
      () {
        expect(
          defaultTileProvider.urlTemplate,
          isNot(contains('tile.openstreetmap.org')),
        );
      },
    );

    group('attribution', () {
      test('has exactly 3 entries', () {
        expect(defaultTileProvider.attribution, hasLength(3));
      });

      test('first entry is Stadia Maps', () {
        expect(defaultTileProvider.attribution[0].text, 'Stadia Maps');
      });

      test('second entry is OpenMapTiles', () {
        expect(defaultTileProvider.attribution[1].text, 'OpenMapTiles');
      });

      test('third entry is OpenStreetMap', () {
        expect(defaultTileProvider.attribution[2].text, 'OpenStreetMap');
      });

      test(
        'OpenStreetMap entry url equals kOsmCopyrightUrl',
        () {
          final osmEntry = defaultTileProvider.attribution
              .firstWhere((a) => a.text == 'OpenStreetMap');
          expect(osmEntry.url, kOsmCopyrightUrl);
        },
      );
    });

    test(
      'apiKeyConfigured is false when only the placeholder is set',
      () {
        // In the test environment no STADIA_API_KEY dart-define is supplied,
        // so stadiaApiKey == stadiaApiKeyPlaceholder.
        expect(defaultTileProvider.apiKeyConfigured, isFalse);
      },
    );
  });

  group('osmRawDevFallback', () {
    test('id is osm_raw_dev', () {
      expect(osmRawDevFallback.id, 'osm_raw_dev');
    });

    test('maxNativeZoom is 19', () {
      expect(osmRawDevFallback.maxNativeZoom, 19);
    });

    test('urlTemplate contains tile.openstreetmap.org', () {
      expect(
        osmRawDevFallback.urlTemplate,
        contains('tile.openstreetmap.org'),
      );
    });

    test('userAgentHeader is not null', () {
      expect(osmRawDevFallback.userAgentHeader, isNotNull);
    });

    test("userAgentHeader contains 'Haven/'", () {
      expect(osmRawDevFallback.userAgentHeader, contains('Haven/'));
    });

    test('requiresApiKey is false', () {
      expect(osmRawDevFallback.requiresApiKey, isFalse);
    });

    test(
      'apiKeyConfigured is true (no key required → always configured)',
      () {
        expect(osmRawDevFallback.apiKeyConfigured, isTrue);
      },
    );
  });

  group('tileCacheKey', () {
    test('strips api_key leaving other params intact', () {
      // URL with api_key alongside another param: api_key is stripped,
      // other param is preserved.
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          '10/512/384.png?style=light&api_key=SECRETKEY';
      final key = tileCacheKey(url);
      expect(key, isNot(contains('SECRETKEY')));
      expect(key, isNot(contains('api_key')));
      expect(key, contains('style=light'));
    });

    test('strips api_key when it is the ONLY query parameter', () {
      // Regression: replace(queryParameters: null) used to keep the original
      // query, leaving the secret in the cache key. The secret must be gone
      // and no dangling "?" left behind.
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          '10/512/384.png?api_key=SECRETKEY';
      final key = tileCacheKey(url);
      expect(key, isNot(contains('SECRETKEY')));
      expect(key, isNot(contains('api_key')));
      expect(
        key,
        'https://tiles.stadiamaps.com/tiles/alidade_smooth/10/512/384.png',
      );
    });

    test('returns URL unchanged when no query parameters', () {
      const url = 'https://tile.openstreetmap.org/10/512/384.png';
      expect(tileCacheKey(url), url);
    });

    test('returns URL unchanged when api_key is absent', () {
      const url =
          'https://tiles.example.com/tile.png?style=dark&zoom=10';
      final key = tileCacheKey(url);
      expect(key, contains('style=dark'));
      expect(key, isNot(contains('api_key')));
    });
  });
}
