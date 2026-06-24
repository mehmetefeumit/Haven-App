/// Tests for the unified [MemberMarker] (clean circle ⇄ edge teardrop).
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart' show kDropletFullDiameter;
import 'package:haven/src/widgets/map/member_marker.dart';

/// A fake [Canvas] recording `drawPath` and `drawImageRect` calls so the
/// private teardrop painter can be inspected without a raster context.
class _RecordingCanvas implements Canvas {
  final List<Color> fillColors = [];
  final List<Color> strokeColors = [];
  Path? lastFillPath;

  /// Non-null when the painter called [drawImageRect].
  ui.Image? drawnImage;
  bool clippedPath = false;

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

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) {
    clippedPath = true;
  }

  @override
  void drawImageRect(
    ui.Image image,
    Rect src,
    Rect dst,
    Paint paint,
  ) {
    drawnImage = image;
  }

  // The painter saves/translates/rotates and lays out initials text; ignore
  // every call other than the recorded ones.
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
  bool exiting = false,
  VoidCallback? onExitComplete,
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
  exiting: exiting,
  onExitComplete: onExitComplete,
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

    testWidgets('reverses the appear transition and reports completion '
        'when exiting', (tester) async {
      var completed = false;
      void onDone() => completed = true;

      await tester.pumpWidget(_wrap(_marker(onExitComplete: onDone)));
      await tester.pump(const Duration(milliseconds: 200)); // appear settles

      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, 1.0, reason: 'fully visible before exiting');

      // Flip to exiting — the keyed marker state is reused and reverses.
      await tester.pumpWidget(
        _wrap(_marker(exiting: true, onExitComplete: onDone)),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(
        fade.opacity.value,
        lessThan(1.0),
        reason: 'opacity is animating back toward zero',
      );
      expect(completed, isFalse, reason: 'still mid fade-out');

      await tester.pump(const Duration(milliseconds: 120));
      expect(completed, isTrue, reason: 'fade-out finished, safe to drop');
    });

    testWidgets('exit completes promptly under reduce motion', (tester) async {
      var completed = false;
      void onDone() => completed = true;

      await tester.pumpWidget(
        _wrap(_marker(onExitComplete: onDone), reduceMotion: true),
      );
      await tester.pump();

      await tester.pumpWidget(
        _wrap(
          _marker(exiting: true, onExitComplete: onDone),
          reduceMotion: true,
        ),
      );
      // A post-frame callback reports completion without a transition.
      await tester.pump();
      expect(completed, isTrue);
    });

    testWidgets('a marker constructed already exiting hides and completes', (
      tester,
    ) async {
      // If the keyed state is NOT reused (e.g. the avatar wrapper is added the
      // same frame the member departs), the marker is born with exiting:true.
      // It must start hidden and report completion, not fade in from nothing.
      var completed = false;
      await tester.pumpWidget(
        _wrap(_marker(exiting: true, onExitComplete: () => completed = true)),
      );
      final fade = tester.widget<FadeTransition>(
        find.descendant(
          of: find.byType(MemberMarker),
          matching: find.byType(FadeTransition),
        ),
      );
      expect(fade.opacity.value, 0.0, reason: 'no frame to fade from → hidden');
      await tester.pump();
      expect(completed, isTrue, reason: 'completes via post-frame callback');
    });
  });

  group('MemberMarker semantics', () {
    testWidgets('on-screen label includes the display name and last-seen age', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', lastSeen: lastSeen)),
      );
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'Jane member marker, last seen 5 minutes ago');
    });

    testWidgets('on-screen label omits "last seen" when fresh / null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(displayName: 'Jane')));
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'Jane member marker');
    });

    testWidgets(
        'on-screen label is generic when no display name (never the '
        'initials/pubkey)', (
      tester,
    ) async {
      // With no display name, markerInitials derives the initials from the
      // pubkey; the on-screen Semantics label must NOT speak them — a screen
      // reader must never announce a pubkey fragment.
      await tester.pumpWidget(_wrap(_marker()));
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'Member marker');
      expect(s.label, isNot(contains('JD')),
          reason: 'a no-display-name marker must not speak its initials');
    });

    testWidgets('off-screen label is directional', (tester) async {
      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', offScreen: true, nubLength: 8)),
      );
      final s = tester.getSemantics(find.byType(MemberMarker));
      expect(s.label, 'Jane is off-screen to the east, tap to view');
    });

    testWidgets('an exiting marker is excluded from the semantics tree', (
      tester,
    ) async {
      // A departed member fading out must not be announced by a screen reader
      // (the fade is a sighted-only flourish; AT should see them gone at once).
      final handle = tester.ensureSemantics();

      await tester.pumpWidget(_wrap(_marker(displayName: 'Jane')));
      expect(
        find.bySemanticsLabel('Jane member marker'),
        findsOneWidget,
        reason: 'a live marker exposes its label',
      );

      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', exiting: true)),
      );
      expect(
        find.bySemanticsLabel('Jane member marker'),
        findsNothing,
        reason: 'an exiting marker is dropped from the semantics tree',
      );

      handle.dispose();
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

  group('MemberMarker avatar', () {
    testWidgets('paints initials glyph when avatarImage is null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _RecordingCanvas();
      _teardrop(tester).painter!.paint(rec, const Size(76, 76));
      // No image was drawn; the fill path (body) is present.
      expect(rec.drawnImage, isNull,
          reason: 'null avatarImage must not call drawImageRect');
      expect(rec.fillColors, isNotEmpty,
          reason: 'body fill must still be drawn');
    });

    testWidgets(
        'paints image and clips to head circle when avatarImage is supplied', (
      tester,
    ) async {
      // createTestImage must run in the real-async zone (runAsync); decoding a
      // ui.Image never completes inside testWidgets' fake-async, which would
      // hang the test.
      final testImage = (await tester.runAsync(
        () => createTestImage(width: 16, height: 16),
      ))!;
      await tester.pumpWidget(
        _wrap(
          MemberMarker(
            initials: 'JD',
            publicKey: _pubkey,
            fillColor: const Color(0xFF8800AA),
            haloColor: const Color(0xFFFFFFFF),
            diameter: kDropletFullDiameter,
            nubLength: 0,
            angle: 0,
            offScreen: false,
            avatarImage: testImage,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _RecordingCanvas();
      _teardrop(tester).painter!.paint(rec, const Size(76, 76));
      // The image was drawn and the canvas was clipped.
      expect(rec.drawnImage, same(testImage),
          reason: 'supplied avatarImage must be drawn via drawImageRect');
      expect(rec.clippedPath, isTrue,
          reason: 'canvas must be clipped to the head circle');
      // The body fill (shadow + halo + fill) is still present.
      expect(rec.fillColors, isNotEmpty,
          reason: 'teardrop body fill must still be drawn');
    });

    testWidgets('shouldRepaint is true when avatarImage changes', (
      tester,
    ) async {
      // Real-async zone required to decode ui.Images (see note above).
      final img1 = (await tester.runAsync(
        () => createTestImage(width: 4, height: 4),
      ))!;
      final img2 = (await tester.runAsync(
        () => createTestImage(width: 4, height: 4),
      ))!;
      await tester.pumpWidget(
        _wrap(
          MemberMarker(
            initials: 'JD',
            publicKey: _pubkey,
            fillColor: const Color(0xFF8800AA),
            haloColor: const Color(0xFFFFFFFF),
            diameter: kDropletFullDiameter,
            nubLength: 0,
            angle: 0,
            offScreen: false,
            avatarImage: img1,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final painter1 =
          _teardrop(tester).painter! as CustomPainter;

      await tester.pumpWidget(
        _wrap(
          MemberMarker(
            initials: 'JD',
            publicKey: _pubkey,
            fillColor: const Color(0xFF8800AA),
            haloColor: const Color(0xFFFFFFFF),
            diameter: kDropletFullDiameter,
            nubLength: 0,
            angle: 0,
            offScreen: false,
            avatarImage: img2,
          ),
        ),
      );
      await tester.pump();
      final painter2 =
          _teardrop(tester).painter! as CustomPainter;

      // The framework calls newPainter.shouldRepaint(oldPainter); painter2 is
      // the new painter, painter1 the old. A different image must repaint.
      expect(painter2.shouldRepaint(painter1), isTrue);
    });

    testWidgets('shouldRepaint is false when avatarImage is identical', (
      tester,
    ) async {
      // Real-async zone required to decode ui.Images (see note above).
      final img = (await tester.runAsync(
        () => createTestImage(width: 4, height: 4),
      ))!;
      await tester.pumpWidget(
        _wrap(
          MemberMarker(
            initials: 'JD',
            publicKey: _pubkey,
            fillColor: const Color(0xFF8800AA),
            haloColor: const Color(0xFFFFFFFF),
            diameter: kDropletFullDiameter,
            nubLength: 0,
            angle: 0,
            offScreen: false,
            avatarImage: img,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      // Same painter instance — shouldRepaint(same_painter) must be false.
      final p = _teardrop(tester).painter! as CustomPainter;
      expect(p.shouldRepaint(p), isFalse);
    });
  });
}
