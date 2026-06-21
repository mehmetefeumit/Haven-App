/// Tests for the unified [MemberMarker] (clean circle ⇄ edge teardrop).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart' show kDropletFullDiameter;
import 'package:haven/src/widgets/map/member_marker.dart';

/// A fake [Canvas] recording `drawPath` calls by paint style and the last
/// filled path, so the private teardrop painter can be inspected without a
/// raster context.
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
  void drawShadow(Path path, Color color, double elevation, bool occluder) {}

  // The painter saves/translates/rotates and lays out initials text; ignore
  // every call other than the recorded drawPath/drawShadow.
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

MemberMarker _marker({
  String initials = 'JD',
  String? displayName,
  Color fill = const Color(0xFF8800AA),
  Color halo = const Color(0xFFFFFFFF),
  double diameter = kDropletFullDiameter,
  double nubLength = 0,
  double angle = 0,
  bool offScreen = false,
  DateTime? lastSeen,
  Offset tapOffset = Offset.zero,
  VoidCallback? onTap,
}) => MemberMarker(
  initials: initials,
  publicKey: _pubkey,
  displayName: displayName,
  fillColor: fill,
  haloColor: halo,
  diameter: diameter,
  nubLength: nubLength,
  angle: angle,
  offScreen: offScreen,
  lastSeen: lastSeen,
  onTap: onTap,
  tapOffset: tapOffset,
);

CustomPaint _teardrop(WidgetTester tester) => tester.widget<CustomPaint>(
  find.byKey(WidgetKeys.markerTeardrop(_pubkey)),
);

void main() {
  group('MemberMarker shape', () {
    testWidgets('on-screen (nubLength 0) paints a plain circle', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _RecordingCanvas();
      _teardrop(tester).painter!.paint(rec, const Size(76, 76));
      // Circle only: filled path reaches the radius, no tail.
      expect(rec.lastFillPath!.getBounds().right, closeTo(26, 1));
    });

    testWidgets('grows an outward tail past the radius when nubLength > 0', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(nubLength: 8)));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _RecordingCanvas();
      _teardrop(tester).painter!.paint(rec, const Size(76, 76));
      expect(rec.lastFillPath!.getBounds().right, greaterThan(29));
    });

    testWidgets('fills the body in the member hue with a surface halo', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _RecordingCanvas();
      _teardrop(tester).painter!.paint(rec, const Size(76, 76));
      expect(rec.fillColors, isNotEmpty);
      expect(rec.strokeColors, isNotEmpty);
      _expectColorMatches(rec.fillColors.last, const Color(0xFF8800AA));
      _expectColorMatches(rec.strokeColors.first, const Color(0xFFFFFFFF));
    });
  });

  group('MemberMarker size', () {
    testWidgets('footprint grows with diameter', (tester) async {
      await tester.pumpWidget(_wrap(_marker(diameter: 20, offScreen: true)));
      await tester.pump(const Duration(milliseconds: 200));
      final small = tester.getSize(find.byType(MemberMarker));

      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final large = tester.getSize(find.byType(MemberMarker));

      expect(small.width, greaterThanOrEqualTo(48));
      expect(large.width, greaterThan(small.width));
    });
  });

  group('MemberMarker motion', () {
    testWidgets('uses a fade/scale appear transition by default', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      expect(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(FadeTransition),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('skips the appear transition under reduce motion', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(), reduceMotion: true));
      expect(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
    });
  });

  group('MemberMarker semantics', () {
    testWidgets('on-screen label includes initials and last-seen age', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen)));
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'JD member marker, last seen 5 minutes ago');
    });

    testWidgets('on-screen label omits "last seen" when fresh / null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'JD member marker');
    });

    testWidgets('off-screen label is directional', (tester) async {
      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', offScreen: true, nubLength: 8)),
      );
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'Jane is off-screen to the east, tap to view');
    });
  });

  group('MemberMarker age pill', () {
    testWidgets('shows the pill for an on-screen marker at age >= 1 min', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('5m'), findsOneWidget);
    });

    testWidgets('keeps the pill for an on-screen marker that has a tail', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen, nubLength: 8)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('5m'), findsOneWidget);
    });

    testWidgets('hides the pill once off-screen', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        _wrap(_marker(lastSeen: lastSeen, offScreen: true, nubLength: 8)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('5m'), findsNothing);
    });
  });

  group('MemberMarker interaction', () {
    testWidgets('fires onTap and keeps a >= 48dp tap target', (tester) async {
      var tapped = false;
      await tester.pumpWidget(_wrap(_marker(onTap: () => tapped = true)));
      await tester.pump(const Duration(milliseconds: 200));

      final gd = find.descendant(
        of: find.byType(MemberMarker),
        matching: find.byType(GestureDetector),
      );
      final s = tester.getSize(gd);
      expect(s.width, greaterThanOrEqualTo(48));
      expect(s.height, greaterThanOrEqualTo(48));

      await tester.tap(find.byType(MemberMarker));
      expect(tapped, isTrue);
    });

    testWidgets('renders no tap target when onTap is null', (tester) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(GestureDetector),
        ),
        findsNothing,
      );
    });

    testWidgets('shifts the tap target inward by tapOffset', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _marker(
            diameter: 20,
            offScreen: true,
            nubLength: 8,
            tapOffset: const Offset(-10, 0),
            onTap: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final markerRect = tester.getRect(find.byType(MemberMarker));
      final tapRect = tester.getRect(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(tapRect.center.dx, closeTo(markerRect.center.dx - 10, 0.5));
      expect(tapRect.width, greaterThanOrEqualTo(48));
    });
  });
}
