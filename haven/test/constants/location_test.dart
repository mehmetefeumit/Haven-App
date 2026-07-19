import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';

void main() {
  group('location constants', () {
    test('kLocationUpdateInterval is 2 minutes (120 seconds)', () {
      // Drift guard: this constant is threaded through the FFI as the
      // nominal for `jitteredPublishIntervalSecs()` and influences the
      // TTL floor passed to `encryptLocation`. A silent change here
      // shifts the NIP-40 expiration window on every published kind:445
      // event.
      expect(kLocationUpdateInterval.inSeconds, 120);
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

    test('kLocationPublishMinInterval is 72s (nominal * 0.6)', () {
      // Authoritative bound lives in Rust at
      // `PUBLISH_INTERVAL_JITTER_FRACTION_BP = 4000` (40% spread).
      // This Dart-side constant is a drift check only.
      expect(
        kLocationPublishMinInterval,
        Duration(seconds: (120 * 0.6).round()),
      );
      expect(kLocationPublishMinInterval.inSeconds, 72);
    });

    test('kStreamPositionMaxAge equals kLocationPublishMaxInterval', () {
      // The stream-position cache serves publish cycles; a fix bounded by
      // the max jittered publish interval is never staler than what an
      // on-time publish tick would have captured. Pinned so the iOS
      // background publish path's freshness bound cannot silently drift.
      expect(kStreamPositionMaxAge, kLocationPublishMaxInterval);
    });

    test('kLocationPublishMaxInterval is 168s (nominal * 1.4)', () {
      expect(
        kLocationPublishMaxInterval,
        Duration(seconds: (120 * 1.4).round()),
      );
      expect(kLocationPublishMaxInterval.inSeconds, 168);
    });

    test('min < nominal < max ordering holds', () {
      expect(kLocationPublishMinInterval, lessThan(kLocationUpdateInterval));
      expect(kLocationUpdateInterval, lessThan(kLocationPublishMaxInterval));
    });

    test('TTL network buffer is positive', () {
      expect(kTtlNetworkBufferSeconds, greaterThan(0));
    });

    test('TTL floor exceeds max publish delay', () {
      // The no-gap invariant: τ_min > δ_max. The TTL floor passed to
      // Rust is `kLocationPublishMaxInterval + kTtlNetworkBufferSeconds`
      // which must strictly exceed the max publish delay.
      expect(
        kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
        greaterThan(kLocationPublishMaxInterval.inSeconds),
      );
    });

    test('motion trigger distance is positive', () {
      expect(kMotionTriggerDistanceMeters, greaterThan(0));
    });
  });
}
