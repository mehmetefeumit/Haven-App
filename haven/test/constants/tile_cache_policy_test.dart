/// Tests for the encrypted tile cache's retention/eviction policy constants.
///
/// Verifies the values documented in
/// `lib/src/constants/tile_cache_policy.dart` and — since `kTileMaxRetention`
/// is quoted verbatim in `privacyInferenceMapTiles` ("...kept in an encrypted
/// cache on your phone for up to seven days") — ties the constant to that ARB
/// string so the two cannot drift apart independently. Reachability (that the
/// constants actually reach the eviction call) is pinned separately in
/// `test/lints/tile_eviction_wiring_test.dart`, since `flutter test` cannot
/// execute the Rust-FFI eviction call itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tile_cache_policy.dart';

import '../helpers/english_arb.dart';

/// English cardinal word for a day count, test-only. The disclosure spells
/// small counts out ("seven days") rather than using a numeral, so the string
/// tie below needs the same rendering. Extend this map before changing
/// [kTileMaxRetention] to a value it does not already cover.
const Map<int, String> _cardinalWords = {
  1: 'one',
  2: 'two',
  3: 'three',
  4: 'four',
  5: 'five',
  6: 'six',
  7: 'seven',
  8: 'eight',
  9: 'nine',
  10: 'ten',
  14: 'fourteen',
};

void main() {
  group('kTileMaxRetention', () {
    test('is 7 days', () {
      expect(kTileMaxRetention, const Duration(days: 7));
    });

    test('matches the day count named in privacyInferenceMapTiles', () {
      final word = _cardinalWords[kTileMaxRetention.inDays];
      expect(
        word,
        isNotNull,
        reason: 'no test-side English word for ${kTileMaxRetention.inDays} '
            'days — add one to _cardinalWords before changing the constant',
      );

      expect(
        englishArb('privacyInferenceMapTiles'),
        contains('$word days'),
        reason: 'privacyInferenceMapTiles no longer names '
            '${kTileMaxRetention.inDays} days (constant and copy have '
            'drifted apart)',
      );
    });
  });

  group('kTileIdlePurgeAge', () {
    // Backs no user-facing string (see file header on
    // tile_cache_policy.dart), but it feeds the same eviction call as
    // kTileMaxRetention, so it is pinned here too.
    test('is 2 days', () {
      expect(kTileIdlePurgeAge, const Duration(days: 2));
    });
  });
}
