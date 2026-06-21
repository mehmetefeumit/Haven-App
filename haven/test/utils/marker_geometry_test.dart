/// Tests for the unified marker geometry (clean circle ⇄ edge teardrop).
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/marker_geometry.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

void main() {
  // A realistic phone viewport with a status bar and a collapsed bottom sheet.
  const size = Size(400, 800);
  const topInset = 24.0;
  const bottomInset = 96.0; // 800 * 0.12
  final vp = edgeViewport(
    viewport: size,
    topInset: topInset,
    bottomInset: bottomInset,
  );

  MarkerProjection project(Offset p) => projectMarker(point: p, viewport: vp);

  group('edgeViewport', () {
    test('safe rect excludes the status bar and the bottom sheet', () {
      expect(vp.safeRect.top, topInset);
      expect(vp.safeRect.bottom, size.height - bottomInset);
      expect(vp.safeRect.left, 0);
      expect(vp.safeRect.right, size.width);
      expect(vp.falloff, 300); // max(160, 0.75 * 400)
    });
  });

  group('projectMarker — on-screen', () {
    test('a member at centre is a full circle on its point', () {
      final center = vp.safeRect.center;
      final p = project(center);
      expect(p.offScreen, isFalse);
      expect(p.diameter, kDropletFullDiameter);
      expect(p.nubLength, 0);
      expect(p.bubbleCenter, center);
    });

    test('full size for ALL on-screen points (guards size-pop)', () {
      for (var x = vp.safeRect.left + 1; x < vp.safeRect.right; x += 40) {
        for (var y = vp.safeRect.top + 1; y < vp.safeRect.bottom; y += 40) {
          expect(project(Offset(x, y)).diameter, kDropletFullDiameter);
          expect(project(Offset(x, y)).offScreen, isFalse);
        }
      }
    });

    test('on-screen but near the edge grows a tail yet stays full size', () {
      // 5px inside the right edge — inside safeRect, outside the place rect.
      final p = project(Offset(vp.safeRect.right - 5, vp.safeRect.center.dy));
      expect(p.offScreen, isFalse);
      expect(p.diameter, kDropletFullDiameter); // not shrunk
      expect(p.nubLength, greaterThan(0)); // tail begins
      expect(compassFromAngle(p.angle), 'east');
    });
  });

  group('projectMarker — off-screen', () {
    test('far east clamps to the right edge, shrinks, points east', () {
      final p = project(Offset(5000, vp.safeRect.center.dy));
      expect(p.offScreen, isTrue);
      expect(p.diameter, kDropletMinDiameter);
      expect(
        p.bubbleCenter.dx,
        closeTo(
          vp.safeRect.right - kDropletEdgeMargin - kDropletMinDiameter / 2,
          0.6,
        ),
      );
      expect(compassFromAngle(p.angle), 'east');
    });

    test('far north clamps to the top edge', () {
      final p = project(Offset(vp.safeRect.center.dx, -5000));
      expect(p.offScreen, isTrue);
      expect(
        p.bubbleCenter.dy,
        closeTo(
          vp.safeRect.top + kDropletEdgeMargin + kDropletMinDiameter / 2,
          0.6,
        ),
      );
      expect(compassFromAngle(p.angle), 'north');
    });

    test('far south clamps above the bottom sheet', () {
      final p = project(Offset(vp.safeRect.center.dx, 5000));
      expect(p.bubbleCenter.dy, lessThan(vp.safeRect.bottom));
      expect(compassFromAngle(p.angle), 'south');
    });

    test('far south-east clamps to the corner and points diagonally', () {
      final p = project(const Offset(5000, 5000));
      expect(p.offScreen, isTrue);
      expect(compassFromAngle(p.angle), 'south-east');
    });

    test('a non-finite projection is off-screen, not a crash', () {
      final p = project(const Offset(double.nan, double.nan));
      expect(p.offScreen, isTrue);
      expect(p.diameter, kDropletMinDiameter);
      expect(p.bubbleCenter.dx.isFinite, isTrue);
    });
  });

  group('continuity (no-pop guards)', () {
    test('all of bubbleCenter/diameter/nub/angle are jump-free across an edge', () {
      // Sweep horizontally through the right edge in small steps.
      MarkerProjection? prev;
      for (var x = 100.0; x <= 700; x += 5) {
        final p = project(Offset(x, vp.safeRect.center.dy));
        if (prev != null) {
          expect((p.diameter - prev.diameter).abs(), lessThan(2));
          expect((p.nubLength - prev.nubLength).abs(), lessThan(7));
          expect(
            (p.bubbleCenter - prev.bubbleCenter).distance,
            lessThan(7),
          );
          // Horizontal sweep stays pointing east (angle ~ 0) the whole way.
          expect(p.angle.abs(), lessThan(0.2));
        }
        prev = p;
      }
    });

    test('angle rotates continuously around a corner with no flip', () {
      // Sweep the true point in a circle of radius 5000 around the centre;
      // the outward angle must move in small steps (no 180-degree flip).
      double? prevAngle;
      for (var deg = 0; deg <= 360; deg += 5) {
        final rad = deg * math.pi / 180;
        final p = project(
          vp.safeRect.center + Offset(math.cos(rad), math.sin(rad)) * 5000,
        );
        if (prevAngle != null) {
          var d = (p.angle - prevAngle).abs();
          if (d > math.pi) d = 2 * math.pi - d; // wrap-around
          expect(d, lessThan(0.3));
        }
        prevAngle = p.angle;
      }
    });
  });

  group('dropletDiameter', () {
    test('full at the edge (== marker ring) and min past the falloff', () {
      expect(dropletDiameter(0, 300), kDropletFullDiameter);
      expect(kDropletFullDiameter, kRingDiameter); // no-pop size match
      expect(dropletDiameter(300, 300), kDropletMinDiameter);
      expect(dropletDiameter(10000, 300), kDropletMinDiameter);
    });

    test('is monotonically non-increasing in overshoot', () {
      var prev = dropletDiameter(0, 300);
      for (var o = 0.0; o <= 300; o += 15) {
        final d = dropletDiameter(o, 300);
        expect(d, lessThanOrEqualTo(prev + 1e-9));
        prev = d;
      }
    });
  });

  group('compassFromAngle', () {
    test('maps the eight screen-space directions (y is south)', () {
      expect(compassFromAngle(0), 'east');
      expect(compassFromAngle(math.pi / 2), 'south');
      expect(compassFromAngle(math.pi), 'west');
      expect(compassFromAngle(-math.pi / 2), 'north');
      expect(compassFromAngle(math.pi / 4), 'south-east');
      expect(compassFromAngle(3 * math.pi / 4), 'south-west');
      expect(compassFromAngle(-math.pi / 4), 'north-east');
      expect(compassFromAngle(-3 * math.pi / 4), 'north-west');
    });
  });

  group('offScreenSemanticsLabel', () {
    test('uses the display name and compass direction', () {
      expect(
        offScreenSemanticsLabel('Jane', 0),
        'Jane is off-screen to the east, tap to view',
      );
    });

    test('falls back to "A member" when nameless or blank', () {
      expect(
        offScreenSemanticsLabel(null, -math.pi / 2),
        'A member is off-screen to the north, tap to view',
      );
      expect(
        offScreenSemanticsLabel('   ', 0),
        'A member is off-screen to the east, tap to view',
      );
    });
  });

  group('tapTargetCenter', () {
    test('biases a tiny edge bubble inward so 48dp stays on-screen', () {
      final far = project(Offset(5000, vp.safeRect.center.dy));
      final center = tapTargetCenter(
        bubbleCenter: far.bubbleCenter,
        diameter: far.diameter,
        safeRect: vp.safeRect,
      );
      expect(
        center.dx,
        lessThanOrEqualTo(vp.safeRect.right - kMinTapTarget / 2 + 1e-6),
      );
      expect(center.dx, lessThan(far.bubbleCenter.dx));
    });

    test('leaves a centre that is already well inside unchanged', () {
      final c = vp.safeRect.center;
      expect(
        tapTargetCenter(
          bubbleCenter: c,
          diameter: kDropletFullDiameter,
          safeRect: vp.safeRect,
        ),
        c,
      );
    });
  });
}
