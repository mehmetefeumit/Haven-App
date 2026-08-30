/// Tests for the encrypted tile cache's retention/eviction policy constants.
///
/// Verifies the values documented in
/// `lib/src/constants/tile_cache_policy.dart`. Reachability (that the
/// constants actually reach the eviction call) is pinned separately in
/// `test/lints/tile_eviction_wiring_test.dart`, since `flutter test` cannot
/// execute the Rust-FFI eviction call itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tile_cache_policy.dart';

void main() {
  group('kTileMaxRetention', () {
    test('is 7 days', () {
      expect(kTileMaxRetention, const Duration(days: 7));
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
