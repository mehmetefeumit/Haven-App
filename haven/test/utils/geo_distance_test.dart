/// Tests for the one shared haversine.
///
/// It is shared, not duplicated, because two copies would be two independent
/// definitions of [kMotionTriggerDistanceMeters]: the motion trigger that
/// decides to publish and the iOS profile controller that decides to leave the
/// coarse accuracy tier must agree on what 100 m is, or a displacement can
/// change the GPS tier without ever producing a publish (or the reverse).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/utils/geo_distance.dart';

void main() {
  group('haversineMeters', () {
    test('is zero for the same point', () {
      expect(haversineMeters(51.5, -0.12, 51.5, -0.12), 0);
    });

    test('one degree of latitude is a meridian degree (111.19 km)', () {
      // 2*pi*6371000/360 = 111194.9 m. Anchored on the mean-radius sphere the
      // formula assumes, so a changed radius constant lands here.
      expect(haversineMeters(0, 0, 1, 0), closeTo(111194.9, 1));
    });

    test('one degree of longitude shrinks with the cosine of the latitude', () {
      final equator = haversineMeters(0, 0, 0, 1);
      final london = haversineMeters(51.5, 0, 51.5, 1);
      expect(equator, closeTo(111194.9, 1));
      // cos(51.5 deg) = 0.6225. A formula that ignored the latitude term
      // would report the equatorial distance here and would let a device
      // "move" 100 m of longitude at a pole for free.
      expect(london, closeTo(111194.9 * 0.62251, 5));
    });

    test('is symmetric in its two points', () {
      final there = haversineMeters(48.8584, 2.2945, 48.8606, 2.3376);
      final back = haversineMeters(48.8606, 2.3376, 48.8584, 2.2945);
      expect(there, back);
    });

    test('resolves the motion-trigger threshold at metre scale', () {
      // The one property both consumers rely on: 100 m must be tellable from
      // 99 m. 0.0008993 deg of latitude is 100.0 m on this sphere.
      const northOf100m = 0.0009;
      const northOf90m = 0.00081;
      expect(
        haversineMeters(51.5, -0.12, 51.5 + northOf100m, -0.12),
        greaterThanOrEqualTo(kMotionTriggerDistanceMeters),
      );
      expect(
        haversineMeters(51.5, -0.12, 51.5 + northOf90m, -0.12),
        lessThan(kMotionTriggerDistanceMeters),
      );
    });

    test('crosses the antimeridian without reporting a trip round the world',
        () {
      // 0.001 deg either side of +/-180. A naive (lon2 - lon1) difference
      // would report ~20 000 km here and pin the profile at Best forever.
      expect(haversineMeters(0, 179.999, 0, -179.999), closeTo(222.4, 1));
    });
  });
}
