/// Tests for [TileKey.tryParse].
///
/// Verifies that the cache-key parser:
/// - Correctly parses all four Stadia styles, retina and non-retina.
/// - Strips the api_key so it never appears in the parsed result.
/// - Returns `null` for the dev OSM fallback and other unrecognised shapes.
///
/// No network calls, no FFI — pure Dart only.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/tile_key.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Golden parses — one per style, retina + non-retina
  // ---------------------------------------------------------------------------

  group('TileKey.tryParse — known styles', () {
    test(
      'alidade_smooth non-retina without api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth/14/8187/5451.png';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.style, 'alidade_smooth');
        expect(key.z, 14);
        expect(key.x, 8187);
        expect(key.y, 5451);
        expect(key.retina, isFalse);
      },
    );

    test(
      'alidade_smooth non-retina WITH api_key — identical result',
      () {
        const urlWithKey =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
            '14/8187/5451.png?api_key=SECRET';
        final key = TileKey.tryParse(urlWithKey);
        expect(key, isNotNull);
        expect(key!.style, 'alidade_smooth');
        expect(key.z, 14);
        expect(key.x, 8187);
        expect(key.y, 5451);
        expect(key.retina, isFalse);
      },
    );

    test(
      'alidade_smooth retina (@2x.png) WITH api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
            '14/8187/5451@2x.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.retina, isTrue);
        expect(key.style, 'alidade_smooth');
        expect(key.z, 14);
        expect(key.x, 8187);
        expect(key.y, 5451);
      },
    );

    test(
      'alidade_smooth_dark non-retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/'
            '10/512/384.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.style, 'alidade_smooth_dark');
        expect(key.z, 10);
        expect(key.x, 512);
        expect(key.y, 384);
        expect(key.retina, isFalse);
      },
    );

    test(
      'alidade_smooth_dark retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/'
            '10/512/384@2x.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.retina, isTrue);
        expect(key.style, 'alidade_smooth_dark');
      },
    );

    test(
      'osm_bright non-retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/osm_bright/'
            '7/63/42.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.style, 'osm_bright');
        expect(key.z, 7);
        expect(key.x, 63);
        expect(key.y, 42);
        expect(key.retina, isFalse);
      },
    );

    test(
      'osm_bright retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/osm_bright/'
            '7/63/42@2x.png?api_key=ANOTHERSECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.retina, isTrue);
        expect(key.style, 'osm_bright');
      },
    );

    test(
      'outdoors non-retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/outdoors/'
            '12/2047/1023.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.style, 'outdoors');
        expect(key.z, 12);
        expect(key.x, 2047);
        expect(key.y, 1023);
        expect(key.retina, isFalse);
      },
    );

    test(
      'outdoors retina with api_key',
      () {
        const url =
            'https://tiles.stadiamaps.com/tiles/outdoors/'
            '12/2047/1023@2x.png?api_key=SECRET';
        final key = TileKey.tryParse(url);
        expect(key, isNotNull);
        expect(key!.retina, isTrue);
        expect(key.style, 'outdoors');
      },
    );
  });

  // ---------------------------------------------------------------------------
  // api_key must NEVER appear in the parsed result
  // ---------------------------------------------------------------------------

  group('TileKey.tryParse — api_key hygiene', () {
    test('result never carries api_key in style', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          '14/8187/5451.png?api_key=TOPSECRET';
      final key = TileKey.tryParse(url)!;
      expect(key.style, isNot(contains('TOPSECRET')));
      expect(key.style, isNot(contains('api_key')));
    });

    test('non-retina and retina of the same tile parse to equal keys', () {
      // Both parse to the same (style, z, x, y) — only retina differs.
      const base = 'https://tiles.stadiamaps.com/tiles/alidade_smooth/14/8187/5451';
      final plain = TileKey.tryParse('$base.png?api_key=A')!;
      final retina = TileKey.tryParse('$base@2x.png?api_key=B')!;
      expect(plain.style, retina.style);
      expect(plain.z, retina.z);
      expect(plain.x, retina.x);
      expect(plain.y, retina.y);
      expect(plain.retina, isFalse);
      expect(retina.retina, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Returns null for unrecognised shapes
  // ---------------------------------------------------------------------------

  group('TileKey.tryParse — null cases', () {
    test('dev OSM fallback returns null', () {
      const url = 'https://tile.openstreetmap.org/10/512/384.png';
      expect(TileKey.tryParse(url), isNull);
    });

    test('empty string returns null', () {
      expect(TileKey.tryParse(''), isNull);
    });

    test('completely garbage input returns null', () {
      expect(TileKey.tryParse('not a url at all'), isNull);
    });

    test('Stadia host but unknown style returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/stamen_watercolor/'
          '10/512/384.png?api_key=SECRET';
      expect(TileKey.tryParse(url), isNull);
    });

    test('Stadia host but wrong path prefix returns null', () {
      const url =
          'https://tiles.stadiamaps.com/static/alidade_smooth/'
          '10/512/384.png';
      expect(TileKey.tryParse(url), isNull);
    });

    test('non-integer z segment returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          'abc/512/384.png';
      expect(TileKey.tryParse(url), isNull);
    });

    test('non-integer x segment returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          '10/xyz/384.png';
      expect(TileKey.tryParse(url), isNull);
    });

    test('non-integer y segment returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/'
          '10/512/abc.png';
      expect(TileKey.tryParse(url), isNull);
    });

    test('missing file extension returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/10/512/384';
      expect(TileKey.tryParse(url), isNull);
    });

    test('jpeg extension returns null', () {
      const url =
          'https://tiles.stadiamaps.com/tiles/alidade_smooth/10/512/384.jpg';
      expect(TileKey.tryParse(url), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Equality / hashCode
  // ---------------------------------------------------------------------------

  group('TileKey equality', () {
    test('two identical keys are equal', () {
      const a = TileKey(
        style: 'alidade_smooth',
        z: 14,
        x: 8187,
        y: 5451,
        retina: false,
      );
      const b = TileKey(
        style: 'alidade_smooth',
        z: 14,
        x: 8187,
        y: 5451,
        retina: false,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('retina difference makes keys unequal', () {
      const a = TileKey(
        style: 'alidade_smooth',
        z: 14,
        x: 8187,
        y: 5451,
        retina: false,
      );
      const b = TileKey(
        style: 'alidade_smooth',
        z: 14,
        x: 8187,
        y: 5451,
        retina: true,
      );
      expect(a, isNot(equals(b)));
    });

    test('style difference makes keys unequal', () {
      const a = TileKey(
        style: 'alidade_smooth',
        z: 10,
        x: 512,
        y: 384,
        retina: false,
      );
      const b = TileKey(
        style: 'osm_bright',
        z: 10,
        x: 512,
        y: 384,
        retina: false,
      );
      expect(a, isNot(equals(b)));
    });
  });
}
