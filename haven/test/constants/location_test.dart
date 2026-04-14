import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';

void main() {
  group('location constants', () {
    test('kLocationUpdateInterval is 5 minutes (300 seconds)', () {
      // Drift guard: this constant is threaded through the FFI as
      // `updateIntervalSecs` and feeds the Rust-side jitter formula
      // `[interval, 2 * interval]`. A silent change here shifts the
      // NIP-40 expiration window on every published kind:445 event.
      expect(kLocationUpdateInterval.inSeconds, 300);
    });

    test('overlap guard is shorter than the full interval', () {
      // The publish-skip guard MUST be less than the full interval,
      // otherwise `Timer.periodic` fires would always be suppressed
      // and location sharing would stop altogether.
      expect(kLocationPublishOverlapGuard, lessThan(kLocationUpdateInterval));
    });

    test('overlap guard is ~90% of the interval', () {
      // Guard against accidental mis-scaling — must remain in a
      // sensible 80-95% band of the full interval.
      final ratio =
          kLocationPublishOverlapGuard.inMilliseconds /
          kLocationUpdateInterval.inMilliseconds;
      expect(ratio, greaterThan(0.80));
      expect(ratio, lessThan(0.95));
    });
  });
}
