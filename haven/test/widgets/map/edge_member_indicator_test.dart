/// Tests for the off-screen member edge indicator ("droplet") widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/edge_member_indicator.dart';

/// A fake [Canvas] that records `drawPath` calls split by paint style and
/// keeps the last filled path, so the private droplet painter can be inspected
/// without a raster context (which `Picture.toImage()` would need).
class _RecordingCanvas implements Canvas {
  final List<Color> fillColors = [];
  final List<Color> strokeColors = [];
  Path? lastFillPath;

  @override
  void drawPath(Path path, Paint paint) {
    if (paint.style == PaintingStyle.stroke) {
      strokeColors.add(paint.color);
    } else {
      fillColors.add(paint.color);
      lastFillPath = path;
    }
  }

  @override
  void drawShadow(
    Path path,
    Color color,
    double elevation,
    bool transparentOccluder,
  ) {
    // Decorative; not recorded.
  }

  // The droplet painter saves/translates/rotates the canvas and lays out
  // initials text; ignore every call other than the recorded drawPath/shadow.
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _expectColorMatches(Color actual, Color expected) {
  const epsilon = 1 / 255;
  expect((actual.a - expected.a).abs(), lessThan(epsilon));
  expect((actual.r - expected.r).abs(), lessThan(epsilon));
  expect((actual.g - expected.g).abs(), lessThan(epsilon));
  expect((actual.b - expected.b).abs(), lessThan(epsilon));
}

const _pubkey = 'deadbeef';

Widget _wrap(Widget child, {bool reduceMotion = false}) => MaterialApp(
  theme: ThemeData.light(),
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(body: Center(child: child)),
  ),
);

EdgeMemberIndicator _indicator({
  double diameter = 52,
  double morph = 1,
  double angle = 0,
  String initials = 'JD',
  Color fill = const Color(0xFF8800AA),
  Color halo = const Color(0xFFFFFFFF),
  String label = 'Jane is off-screen to the east, tap to view',
  Offset tapOffset = Offset.zero,
  VoidCallback? onTap,
}) => EdgeMemberIndicator(
  initials: initials,
  publicKey: _pubkey,
  fillColor: fill,
  haloColor: halo,
  diameter: diameter,
  morph: morph,
  angle: angle,
  semanticsLabel: label,
  onTap: onTap ?? () {},
  tapOffset: tapOffset,
);

CustomPaint _droplet(WidgetTester tester) => tester.widget<CustomPaint>(
  find.byKey(WidgetKeys.edgeIndicatorDroplet(_pubkey)),
);

void main() {
  group('EdgeMemberIndicator size', () {
    testWidgets('footprint grows with diameter and stays >= 48dp', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_indicator(diameter: 20, morph: 0)));
      await tester.pump(const Duration(milliseconds: 200));
      final small = tester.getSize(find.byType(EdgeMemberIndicator));

      await tester.pumpWidget(_wrap(_indicator()));
      await tester.pump(const Duration(milliseconds: 200));
      final large = tester.getSize(find.byType(EdgeMemberIndicator));

      expect(small.width, greaterThanOrEqualTo(48));
      expect(large.width, greaterThan(small.width));
    });

    testWidgets('keeps a >= 48dp tap target even when tiny', (tester) async {
      await tester.pumpWidget(_wrap(_indicator(diameter: 20, morph: 0)));
      await tester.pump(const Duration(milliseconds: 200));
      final tapTarget = find.descendant(
        of: find.byType(EdgeMemberIndicator),
        matching: find.byType(GestureDetector),
      );
      final tapSize = tester.getSize(tapTarget);
      expect(tapSize.width, greaterThanOrEqualTo(48));
      expect(tapSize.height, greaterThanOrEqualTo(48));
    });

    testWidgets('shifts the tap target inward by tapOffset', (tester) async {
      // Near a screen edge the layer biases the hit-box inward so the full
      // 48dp target stays reachable while the droplet stays welded to the edge.
      await tester.pumpWidget(
        _wrap(
          _indicator(diameter: 20, morph: 0, tapOffset: const Offset(-10, 0)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final indicatorRect = tester.getRect(find.byType(EdgeMemberIndicator));
      final tapRect = tester.getRect(
        find.descendant(
          of: find.byType(EdgeMemberIndicator),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(tapRect.center.dx, closeTo(indicatorRect.center.dx - 10, 0.5));
      expect(tapRect.center.dy, closeTo(indicatorRect.center.dy, 0.5));
      expect(tapRect.width, greaterThanOrEqualTo(48));
    });
  });

  group('EdgeMemberIndicator painter', () {
    testWidgets('fills the body in the member hue with a surface halo', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_indicator()));
      await tester.pump(const Duration(milliseconds: 200));

      final recorded = _RecordingCanvas();
      _droplet(tester).painter!.paint(recorded, const Size(76, 76));

      expect(recorded.fillColors, isNotEmpty);
      expect(recorded.strokeColors, isNotEmpty);
      // Body fill is the member hue (helper default); halo is the surface tone.
      _expectColorMatches(recorded.fillColors.last, const Color(0xFF8800AA));
      _expectColorMatches(recorded.strokeColors.first, const Color(0xFFFFFFFF));
    });

    testWidgets('nub retracts at the hand-off and extends when far', (
      tester,
    ) async {
      // morph 1 (default) → plain circle: the filled path reaches the radius.
      await tester.pumpWidget(_wrap(_indicator()));
      await tester.pump(const Duration(milliseconds: 200));
      final circle = _RecordingCanvas();
      _droplet(tester).painter!.paint(circle, const Size(76, 76));
      final circleBounds = circle.lastFillPath!.getBounds();
      expect(circleBounds.right, closeTo(26, 1));

      // morph 0 → teardrop: the tip extends past the radius along the ray.
      await tester.pumpWidget(_wrap(_indicator(morph: 0)));
      await tester.pump(const Duration(milliseconds: 200));
      final teardrop = _RecordingCanvas();
      _droplet(tester).painter!.paint(teardrop, const Size(76, 76));
      final teardropBounds = teardrop.lastFillPath!.getBounds();
      expect(teardropBounds.right, greaterThan(circleBounds.right + 3));
    });
  });

  group('EdgeMemberIndicator motion', () {
    testWidgets('uses a fade/scale appear transition by default', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_indicator()));
      expect(
        find.descendant(
          of: find.byType(EdgeMemberIndicator),
          matching: find.byType(FadeTransition),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('skips the appear transition under reduce motion', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_indicator(), reduceMotion: true));
      expect(
        find.descendant(
          of: find.byType(EdgeMemberIndicator),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
    });
  });

  group('EdgeMemberIndicator accessibility & tap', () {
    testWidgets('exposes a button label and fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(_indicator(onTap: () => tapped = true)));
      await tester.pump(const Duration(milliseconds: 200));

      final semantics = tester.getSemantics(find.byType(EdgeMemberIndicator));
      expect(semantics.label, 'Jane is off-screen to the east, tap to view');

      await tester.tap(find.byType(EdgeMemberIndicator));
      expect(tapped, isTrue);
    });
  });
}
