/// The foreground tier is the tolerance every cold start and every resume
/// refreshes profiles at (owner-directed 2026-11-26).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/profile_refresh_tiers.dart';

void main() {
  test('every foreground transition refreshes at a one-minute floor', () {
    expect(profileForegroundMaxAge, const Duration(minutes: 1));
  });

  test('the foreground tier is never the forced mode', () {
    expect(
      profileForegroundMaxAge,
      greaterThan(profileForceMaxAge),
      reason:
          'zero forces a fetch of every pubkey and skips the per-author '
          'miss backoff in Rust; an automatic trigger on every resume must '
          'not do either',
    );
    expect(profileForceMaxAge, Duration.zero);
  });
}
