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

  Offset tipOf(MarkerProjection m) =>
      m.bubbleCenter +
      Offset.fromDirection(m.angle, m.diameter / 2 + m.nubLength);

  double wrap(double a) {
    final t = a % (2 * math.pi);
    return t > math.pi ? t - 2 * math.pi : t;
  }

  // The head can sit on the point at the top edge, ~52 px under the inset.
  bool inTopBand(Offset p) => p.dy - vp.safeRect.top < 56 + 1e-6;

  // Every on-screen grid point, plus the 4 px band at each edge at 0.5 px.
  List<Offset> onScreenGrid() {
    final r = vp.safeRect;
    final pts = <Offset>[];
    for (var x = r.left; x <= r.right; x += 7) {
      for (var y = r.top; y <= r.bottom; y += 7) {
        pts.add(Offset(x, y));
      }
    }
    for (var o = 0.0; o <= 4; o += 0.5) {
      for (var t = 0.0; t <= 1; t += 1 / 40) {
        final x = r.left + t * r.width;
        final y = r.top + t * r.height;
        pts
          ..add(Offset(x, r.top + o))
          ..add(Offset(x, r.bottom - o))
          ..add(Offset(r.left + o, y))
          ..add(Offset(r.right - o, y));
      }
    }
    return pts;
  }

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
    test('a member at centre is a full pin whose tip is on its point', () {
      final center = vp.safeRect.center;
      final p = project(center);
      expect(p.offScreen, isFalse);
      expect(p.diameter, kDropletFullDiameter);
      expect(p.nubLength, closeTo(kDropletOnScreenTail, 1e-9));
      expect(p.angle, closeTo(math.pi / 2, 1e-9));
      expect(p.bubbleCenter, center - const Offset(0, 36));
      expect((tipOf(p) - center).distance, lessThan(1e-6));
    });

    test('full size for ALL on-screen points (guards size-pop)', () {
      for (var x = vp.safeRect.left + 1; x < vp.safeRect.right; x += 40) {
        for (var y = vp.safeRect.top + 1; y < vp.safeRect.bottom; y += 40) {
          expect(project(Offset(x, y)).diameter, kDropletFullDiameter);
          expect(project(Offset(x, y)).offScreen, isFalse);
        }
      }
    });

    test('on-screen near the edge holds the head and keeps the tip on it', () {
      // 5px inside the right edge: on-screen, so not off-screen, full size,
      // the head held 30 px in and the tail stretched to reach the point.
      final pt = Offset(vp.safeRect.right - 5, vp.safeRect.center.dy);
      final p = project(pt);
      expect(p.offScreen, isFalse);
      expect(p.bearing, 0);
      expect(p.diameter, kDropletFullDiameter);
      expect(p.bubbleCenter.dx, vp.safeRect.right - 30);
      expect(p.nubLength, greaterThan(kDropletOnScreenTail));
      expect((tipOf(p) - pt).distance, lessThan(1e-6));
    });

    test('the tip is on every on-screen point outside the top band', () {
      for (final pt in onScreenGrid().where((q) => !inTopBand(q))) {
        final p = project(pt);
        expect(p.nubLength, greaterThan(0), reason: 'point $pt');
        expect(
          (tipOf(p) - pt).distance,
          lessThan(1e-6),
          reason: 'point $pt',
        );
      }
    });

    test('the head stays wholly inside the safe rect on-screen', () {
      for (final pt in onScreenGrid()) {
        final p = project(pt);
        final r = p.diameter / 2;
        final inner = vp.safeRect.deflate(r + 4);
        expect(p.bubbleCenter.dx, greaterThanOrEqualTo(inner.left - 1e-9));
        expect(p.bubbleCenter.dx, lessThanOrEqualTo(inner.right + 1e-9));
        expect(p.bubbleCenter.dy, greaterThanOrEqualTo(inner.top - 1e-9));
        expect(p.bubbleCenter.dy, lessThanOrEqualTo(inner.bottom + 1e-9));
      }
    });

    test('the head is inside the safe rect for every point, even off', () {
      final r = vp.safeRect;
      for (var x = r.left - 400; x <= r.right + 400; x += 23) {
        for (var y = r.top - 400; y <= r.bottom + 400; y += 23) {
          final p = project(Offset(x, y));
          expect(r.contains(p.bubbleCenter), isTrue, reason: 'point $x,$y');
        }
      }
    });

    test('top band: the tail shrinks to a circle, regrows pointing up', () {
      final r = vp.safeRect;
      var sawZero = false;
      double? firstZeroDepth;
      var regrewUp = false;
      var prevNub = double.infinity;
      for (var y = r.center.dy; y >= r.top; y -= 0.25) {
        final p = project(Offset(r.center.dx, y));
        if (p.nubLength == 0) {
          sawZero = true;
          firstZeroDepth ??= y - r.top;
        } else if (sawZero) {
          regrewUp = true;
          expect(math.sin(p.angle), lessThan(0), reason: 'y $y');
          expect(p.nubLength, greaterThan(prevNub - 1e-9));
        } else {
          expect(p.nubLength, lessThanOrEqualTo(prevNub + 1e-9));
        }
        prevNub = p.nubLength;
      }
      expect(sawZero, isTrue);
      expect(regrewUp, isTrue);
      expect(firstZeroDepth, lessThanOrEqualTo(56 + 1e-6));
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
      expect(compassDirectionFromAngle(p.angle), CompassDirection.east);
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
      expect(compassDirectionFromAngle(p.angle), CompassDirection.north);
    });

    test('far south clamps above the bottom sheet', () {
      final p = project(Offset(vp.safeRect.center.dx, 5000));
      expect(p.bubbleCenter.dy, lessThan(vp.safeRect.bottom));
      expect(compassDirectionFromAngle(p.angle), CompassDirection.south);
    });

    test('far south-east clamps to the corner and points diagonally', () {
      final p = project(const Offset(5000, 5000));
      expect(p.offScreen, isTrue);
      expect(compassDirectionFromAngle(p.angle), CompassDirection.southEast);
    });

    test('a non-finite projection is off-screen, not a crash', () {
      final p = project(const Offset(double.nan, double.nan));
      expect(p.offScreen, isTrue);
      expect(p.diameter, kDropletMinDiameter);
      expect(p.bubbleCenter.dx.isFinite, isTrue);
      expect(p.nubLength, kDropletMaxTailFar);
      expect(p.angle, 0);
      expect(p.bearing, 0);
    });

    test('far from an edge: bead welded 4 px in, 8 px tail at the point', () {
      final r = vp.safeRect;
      final mid = r.center;
      final cases = <(Offset, Offset)>[
        (
          Offset(r.right + vp.falloff + 40, mid.dy),
          Offset(r.right - 14, mid.dy),
        ),
        (
          Offset(r.left - vp.falloff - 40, mid.dy),
          Offset(r.left + 14, mid.dy),
        ),
        (
          Offset(mid.dx, r.top - vp.falloff - 40),
          Offset(mid.dx, r.top + 14),
        ),
        (
          Offset(mid.dx, r.bottom + vp.falloff + 40),
          Offset(mid.dx, r.bottom - 14),
        ),
      ];
      for (final (pt, head) in cases) {
        final p = project(pt);
        expect(p.diameter, kDropletMinDiameter);
        expect(p.nubLength, kDropletMaxTailFar);
        expect((p.bubbleCenter - head).distance, lessThan(1e-9));
        final dir = (pt - head) / (pt - head).distance;
        expect(
          (Offset.fromDirection(p.angle) - dir).distance,
          lessThan(1e-9),
        );
      }
    });
  });

  group('bearing', () {
    test('a point just past a side edge is orthogonal, never diagonal', () {
      final r = vp.safeRect;
      final mid = r.center;
      for (final o in [10.0, 20.0]) {
        CompassDirection dir(Offset pt) =>
            compassDirectionFromAngle(project(pt).bearing);
        expect(dir(Offset(r.right + o, mid.dy)), CompassDirection.east);
        expect(dir(Offset(r.left - o, mid.dy)), CompassDirection.west);
        expect(dir(Offset(mid.dx, r.top - o)), CompassDirection.north);
        expect(dir(Offset(mid.dx, r.bottom + o)), CompassDirection.south);
      }
    });

    test('a corner overshoot is diagonal', () {
      final r = vp.safeRect;
      final p = project(Offset(r.right + 20, r.bottom + 20));
      expect(compassDirectionFromAngle(p.bearing), CompassDirection.southEast);
    });

    test('is 0 on-screen', () {
      expect(project(vp.safeRect.center).bearing, 0);
    });

    test('the tail angle alone would misreport the direction (the defect)', () {
      final r = vp.safeRect;
      final p = project(Offset(r.right + 20, r.center.dy));
      expect(
        compassDirectionFromAngle(p.angle),
        isNot(CompassDirection.east),
      );
      expect(compassDirectionFromAngle(p.bearing), CompassDirection.east);
    });
  });

  group('aimTail', () {
    test('no tail while the point is inside the rim', () {
      final t = aimTail(
        point: const Offset(105, 100),
        center: const Offset(100, 100),
        radius: 10,
        cap: 22,
      );
      expect(t.nubLength, 0);
      expect(t.angle, 0);
    });

    test('length is rim to point, limited by the cap', () {
      const c = Offset(100, 100);
      expect(
        aimTail(point: const Offset(100, 120), center: c, radius: 10, cap: 22)
            .nubLength,
        closeTo(10, 1e-12),
      );
      final capped = aimTail(
        point: const Offset(100, 500),
        center: c,
        radius: 10,
        cap: 22,
      );
      expect(capped.nubLength, 22);
      expect(capped.angle, closeTo(math.pi / 2, 1e-12));
    });

    test('coincident point and centre aim down, not at zero', () {
      final t = aimTail(
        point: const Offset(100, 100),
        center: const Offset(100, 100),
        radius: 26,
        cap: 22,
      );
      expect(t.angle, math.pi / 2);
      expect(t.nubLength, 0);
    });

    test('the cap eases from the clinging cap to the far cap', () {
      expect(tailCapFor(0), 22);
      expect(tailCapFor(1), 8);
      expect(tailCapFor(0.5), closeTo(15, 1e-12));
    });

    test('a projection carries the cap of its own shrink progress', () {
      final r = vp.safeRect;
      final onScreen = project(r.center);
      expect(onScreen.tailCap, tailCapFor(0));

      const overshoot = 100.0;
      final past = project(Offset(r.right + overshoot, r.center.dy));
      expect(
        past.tailCap,
        closeTo(tailCapFor(dropletProgress(overshoot, vp.falloff)), 1e-12),
      );
      expect(past.nubLength, lessThanOrEqualTo(past.tailCap));

      final far = project(Offset(r.right + 10 * vp.falloff, r.center.dy));
      expect(far.tailCap, tailCapFor(1));
    });
  });

  group('continuity (no-pop guards)', () {
    // A point crossing one edge or corner on a straight line, 0.25 px steps,
    // from 60 px inside to a full falloff and 60 px beyond.
    void sweep(Offset out) {
      final r = vp.safeRect;
      final anchor = Offset(
        out.dx > 0 ? r.right : (out.dx < 0 ? r.left : r.center.dx),
        out.dy > 0 ? r.bottom : (out.dy < 0 ? r.top : r.center.dy),
      );
      final unit = out / out.distance;
      final steps = ((vp.falloff + 120) / 0.25).round();
      final start = anchor - unit * 60;
      MarkerProjection? prev;
      for (var i = 0; i <= steps; i++) {
        final p = project(start + unit * (0.25 * i));
        if (prev != null) {
          final at = 'dir $out step $i';
          expect(
            (p.bubbleCenter - prev.bubbleCenter).distance,
            lessThan(1),
            reason: at,
          );
          expect((p.diameter - prev.diameter).abs(), lessThan(0.5), reason: at);
          expect(
            (p.nubLength - prev.nubLength).abs(),
            lessThan(0.5),
            reason: at,
          );
          if (p.nubLength >= 0.5 || prev.nubLength >= 0.5) {
            expect(
              wrap(p.angle - prev.angle).abs(),
              lessThan(0.1),
              reason: at,
            );
          }
        }
        prev = p;
      }
    }

    for (final (name, dir) in <(String, Offset)>[
      ('right', const Offset(1, 0)),
      ('left', const Offset(-1, 0)),
      ('top', const Offset(0, -1)),
      ('bottom', const Offset(0, 1)),
      ('top-right', const Offset(1, -1)),
      ('top-left', const Offset(-1, -1)),
      ('bottom-right', const Offset(1, 1)),
      ('bottom-left', const Offset(-1, 1)),
    ]) {
      test('every field is jump-free crossing the $name', () => sweep(dir));
    }

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

    test('has zero slope at the edge (smoothstep, not ease-out)', () {
      // Smoothstep loses 32 * (3e-4 - 2e-6) = 0.0095 px at 1% of the falloff;
      // the old ease-out cubic lost 0.95 px.
      expect(52 - dropletDiameter(3, 300), lessThan(0.02));
      expect(dropletProgress(0, 300), 0);
      expect(dropletProgress(300, 300), 1);
      expect(dropletProgress(150, 300), closeTo(0.5, 1e-12));
    });

    test('is monotonically non-increasing in overshoot', () {
      var prev = dropletDiameter(0, 300);
      for (var o = 0.0; o <= 320; o += 0.5) {
        final d = dropletDiameter(o, 300);
        expect(d, lessThanOrEqualTo(prev + 1e-9));
        prev = d;
      }
    });
  });

  group('compassDirectionFromAngle', () {
    test('maps the eight screen-space directions (y is south)', () {
      // Bearing is real geography: the same enum regardless of layout
      // direction (RTL never mirrors it; only its localized word changes).
      expect(compassDirectionFromAngle(0), CompassDirection.east);
      expect(compassDirectionFromAngle(math.pi / 2), CompassDirection.south);
      expect(compassDirectionFromAngle(math.pi), CompassDirection.west);
      expect(compassDirectionFromAngle(-math.pi / 2), CompassDirection.north);
      expect(
        compassDirectionFromAngle(math.pi / 4),
        CompassDirection.southEast,
      );
      expect(
        compassDirectionFromAngle(3 * math.pi / 4),
        CompassDirection.southWest,
      );
      expect(
        compassDirectionFromAngle(-math.pi / 4),
        CompassDirection.northEast,
      );
      expect(
        compassDirectionFromAngle(-3 * math.pi / 4),
        CompassDirection.northWest,
      );
    });

    test('every sector resolves to a direction across a full sweep', () {
      // No angle should be left unmapped (guards the index modulo).
      for (var deg = 0; deg < 360; deg += 3) {
        final rad = deg * math.pi / 180;
        final dir = compassDirectionFromAngle(rad);
        expect(CompassDirection.values, contains(dir));
      }
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
