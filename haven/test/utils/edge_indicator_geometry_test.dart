/// Tests for the pure off-screen edge-indicator geometry.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/edge_indicator_geometry.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

void main() {
  // A realistic phone viewport with a status bar and a collapsed bottom sheet.
  const size = Size(400, 800);
  const topInset = 24.0;
  const bottomInset = 96.0; // 800 * 0.12
  final viewport = edgeViewport(
    viewport: size,
    topInset: topInset,
    bottomInset: bottomInset,
  );

  EdgeProjection project(Offset avatarCenter) =>
      projectMemberToEdge(avatarCenter: avatarCenter, viewport: viewport);

  group('edgeViewport', () {
    test('safe rect excludes the status bar and the bottom sheet', () {
      expect(viewport.safeRect.top, topInset);
      expect(viewport.safeRect.bottom, size.height - bottomInset);
      expect(viewport.safeRect.left, 0);
      expect(viewport.safeRect.right, size.width);
    });

    test('optical centre is biased above the geometric centre', () {
      expect(viewport.opticalCenter.dx, size.width / 2);
      expect(
        viewport.opticalCenter.dy,
        (topInset + (size.height - bottomInset)) / 2,
      );
      // The bias keeps a due-south member readable above the sheet.
      expect(viewport.opticalCenter.dy, lessThan(size.height / 2));
    });
  });

  group('projectMemberToEdge — on/off screen', () {
    test('a member inside the hand-off rect is on-screen', () {
      final p = project(viewport.opticalCenter + const Offset(10, 10));
      expect(p.offScreen, isFalse);
    });

    test('a member at the optical centre is on-screen (degenerate ray)', () {
      final p = project(viewport.opticalCenter);
      expect(p.offScreen, isFalse);
    });

    test('a far member is off-screen', () {
      expect(project(const Offset(5000, 0)).offScreen, isTrue);
    });

    test('a non-finite projection is off-screen, not a crash', () {
      final p = project(const Offset(double.nan, double.nan));
      expect(p.offScreen, isTrue);
      expect(p.diameter, kDropletMinDiameter);
    });
  });

  group('projectMemberToEdge — edge placement', () {
    test('due east clamps to the right edge at optical-centre height', () {
      final p = project(Offset(5000, viewport.opticalCenter.dy));
      expect(p.offScreen, isTrue);
      expect(
        p.headCenter.dx,
        closeTo(
          viewport.safeRect.right -
              kDropletEdgeMargin -
              kDropletMinDiameter / 2,
          0.6,
        ),
      );
      expect(p.headCenter.dy, closeTo(viewport.opticalCenter.dy, 0.6));
      expect(compassFromAngle(p.angle), 'east');
    });

    test('due north clamps to the top edge', () {
      final p = project(Offset(viewport.opticalCenter.dx, -5000));
      expect(
        p.headCenter.dy,
        closeTo(
          viewport.safeRect.top + kDropletEdgeMargin + kDropletMinDiameter / 2,
          0.6,
        ),
      );
      expect(compassFromAngle(p.angle), 'north');
    });

    test('due south clamps above the bottom sheet', () {
      final p = project(Offset(viewport.opticalCenter.dx, 5000));
      expect(p.headCenter.dy, lessThan(viewport.safeRect.bottom));
      expect(compassFromAngle(p.angle), 'south');
    });

    test('a member along the corner ray reports isCorner', () {
      final cornerDir =
          Offset(viewport.handoffRect.right, viewport.handoffRect.bottom) -
          viewport.opticalCenter;
      final p = project(viewport.opticalCenter + cornerDir * 10);
      expect(p.isCorner, isTrue);
      expect(compassFromAngle(p.angle), 'south-east');
    });

    test('hands off with no positional jump at the edge (no-pop guard)', () {
      // An avatar centre exactly on the hand-off boundary: the droplet must be
      // full size and land precisely where the real marker will appear.
      final avatarCenter = Offset(
        viewport.handoffRect.right,
        viewport.opticalCenter.dy,
      );
      final p = project(avatarCenter);
      expect(p.offScreen, isTrue);
      expect(p.diameter, closeTo(kDropletFullDiameter, 0.001));
      expect(p.headCenter.dx, closeTo(avatarCenter.dx, 0.6));
      expect(p.headCenter.dy, closeTo(avatarCenter.dy, 0.6));
    });
  });

  group('dropletDiameter', () {
    test('equals the marker ring diameter at the hand-off (no-pop guard)', () {
      expect(dropletDiameter(0, 300), kDropletFullDiameter);
      // The whole no-pop promise: the droplet reaches the real marker's ring.
      expect(kDropletFullDiameter, kRingDiameter);
    });

    test('shrinks to the minimum at and beyond the falloff distance', () {
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

  group('dropletMorph', () {
    test('is 1 at the edge and 0 at/beyond the falloff', () {
      expect(dropletMorph(0, 300), 1);
      expect(dropletMorph(300, 300), 0);
      expect(dropletMorph(600, 300), 0);
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

  group('tapTargetCenter', () {
    test('biases a tiny edge droplet inward so 48dp stays on-screen', () {
      // A min-size droplet head sits ~14dp inside the right edge.
      final head = Offset(
        viewport.safeRect.right - kDropletEdgeMargin - kDropletMinDiameter / 2,
        viewport.opticalCenter.dy,
      );
      final center = tapTargetCenter(
        head: head,
        diameter: kDropletMinDiameter,
        safeRect: viewport.safeRect,
      );
      // The 48dp tap box centre must be >= 24dp from the right edge...
      expect(
        center.dx,
        lessThanOrEqualTo(viewport.safeRect.right - kMinTapTarget / 2 + 1e-6),
      );
      // ...so it is biased inward from the head, but the free axis is left be.
      expect(center.dx, lessThan(head.dx));
      expect(center.dy, head.dy);
    });

    test('leaves a head that is already well inside unchanged', () {
      final head = viewport.opticalCenter + const Offset(30, 0);
      final center = tapTargetCenter(
        head: head,
        diameter: kDropletFullDiameter,
        safeRect: viewport.safeRect,
      );
      expect(center, head);
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
}
