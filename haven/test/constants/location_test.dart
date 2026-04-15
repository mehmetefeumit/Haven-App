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

    test('overlap guard is strictly below min jittered interval', () {
      // The publish-skip guard MUST sit below the minimum jittered
      // publish interval, otherwise genuine short-end jittered ticks
      // would be suppressed and the jitter distribution would become
      // biased upward.
      expect(
        kLocationPublishOverlapGuard,
        lessThan(kLocationPublishMinInterval),
      );
    });

    test('kLocationPublishMinInterval is 180s (nominal * 0.6)', () {
      // Authoritative bound lives in Rust at
      // `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4000` (40% spread).
      // This Dart-side constant is a drift check only.
      expect(
        kLocationPublishMinInterval,
        Duration(seconds: (300 * 0.6).round()),
      );
      expect(kLocationPublishMinInterval.inSeconds, 180);
    });

    test('kLocationPublishMaxInterval is 420s (nominal * 1.4)', () {
      expect(
        kLocationPublishMaxInterval,
        Duration(seconds: (300 * 1.4).round()),
      );
      expect(kLocationPublishMaxInterval.inSeconds, 420);
    });

    test('min < nominal < max ordering holds', () {
      expect(kLocationPublishMinInterval, lessThan(kLocationUpdateInterval));
      expect(kLocationUpdateInterval, lessThan(kLocationPublishMaxInterval));
    });
  });
}
