/// Tests for the unified [MemberMarker] (clean circle ⇄ edge teardrop).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/marker_geometry.dart' show kDropletFullDiameter;
import 'package:haven/src/widgets/map/member_marker.dart';

/// One recorded canvas operation, in call order.
class _Op {
  const _Op(this.kind, {this.path, this.color, this.width, this.hasShader});

  final String kind;
  final Path? path;
  final Color? color;
  final double? width;
  final bool? hasShader;
}

/// A fake [Canvas] recording the painter's calls, in order, so the private
/// painter can be inspected without a raster context.
class _RecordingCanvas implements Canvas {
  final List<_Op> ops = [];

  /// Non-null when the painter called [drawImageRect].
  ui.Image? drawnImage;

  List<_Op> get strokes => [
    for (final o in ops)
      if (o.kind == 'stroke') o,
  ];
  _Op get fill => ops.firstWhere((o) => o.kind == 'fill');
  _Op get shadow => ops.firstWhere((o) => o.kind == 'shadow');
  List<String> get kinds => [for (final o in ops) o.kind];

  @override
  void drawPath(Path path, Paint paint) {
    final stroke = paint.style == PaintingStyle.stroke;
    ops.add(
      _Op(
        stroke ? 'stroke' : 'fill',
        path: path,
        color: paint.color,
        width: paint.strokeWidth,
        hasShader: paint.shader != null,
      ),
    );
  }

  @override
  void drawShadow(Path path, Color color, double elevation, bool occluder) =>
      ops.add(_Op('shadow', path: path, color: color, width: elevation));

  @override
  void clipPath(Path path, {bool doAntiAlias = true}) =>
      ops.add(const _Op('clip'));

  @override
  void rotate(double radians) => ops.add(const _Op('rotate'));

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    drawnImage = image;
    ops.add(const _Op('image'));
  }

  // The painter saves/restores and lays out initials text; ignore every call
  // other than the recorded ones.
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
const _white = Color(0xFFFFFFFF);
const _footprint = 120.0;

/// The path's true extent. `Path.getBounds` includes the control points of the
/// arc's conic segments, which stand well outside the circle at the back.
Rect _tightBounds(Path path) {
  final metric = path.computeMetrics().first;
  var rect = Rect.fromPoints(
    metric.getTangentForOffset(0)!.position,
    metric.getTangentForOffset(0)!.position,
  );
  for (var o = 0.0; o <= metric.length; o += 0.05) {
    final p = metric.getTangentForOffset(o)!.position;
    rect = rect.expandToInclude(Rect.fromLTWH(p.dx, p.dy, 0, 0));
  }
  return rect;
}

Widget _wrap(
  Widget child, {
  bool reduceMotion = false,
  Locale? locale,
  ThemeData? theme,
  double textScale = 1,
}) => MaterialApp(
  theme: theme ?? ThemeData.light(),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(
      disableAnimations: reduceMotion,
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(body: Center(child: child)),
  ),
);

MemberMarker _marker({
  String initials = 'JD',
  String publicKey = _pubkey,
  String? displayName,
  double diameter = kDropletFullDiameter,
  double nubLength = 0,
  double angle = 0,
  double bearing = 0,
  bool offScreen = false,
  DateTime? lastSeen,
  Offset tapOffset = Offset.zero,
  VoidCallback? onTap,
  bool exiting = false,
  VoidCallback? onExitComplete,
  ui.Image? avatarImage,
}) => MemberMarker(
  initials: initials,
  publicKey: publicKey,
  displayName: displayName,
  diameter: diameter,
  nubLength: nubLength,
  angle: angle,
  bearing: bearing,
  offScreen: offScreen,
  lastSeen: lastSeen,
  onTap: onTap,
  tapOffset: tapOffset,
  exiting: exiting,
  onExitComplete: onExitComplete,
  avatarImage: avatarImage,
);

/// Paints the teardrop of the pumped marker onto a recording canvas.
_RecordingCanvas _paintMarker(WidgetTester tester, [String key = _pubkey]) {
  final rec = _RecordingCanvas();
  tester
      .widget<CustomPaint>(find.byKey(WidgetKeys.markerTeardrop(key)))
      .painter!
      .paint(rec, const Size.square(_footprint));
  return rec;
}

Finder _inMarker(Finder matching) =>
    find.descendant(of: find.byType(MemberMarker), matching: matching);

SemanticsNode _semantics(WidgetTester tester) =>
    tester.getSemantics(find.byKey(WidgetKeys.markerSemantics(_pubkey)));

/// Hosts [marker] with its head centred at [head] inside a [size] viewport at
/// the top-left of the screen, the way the layer positions it.
Widget _placed(MemberMarker marker, Offset head, Size size) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Align(
    alignment: Alignment.topLeft,
    child: SizedBox.fromSize(
      size: size,
      child: Stack(
        children: [
          Positioned(
            left: head.dx - _footprint / 2,
            top: head.dy - _footprint / 2,
            width: _footprint,
            height: _footprint,
            child: marker,
          ),
        ],
      ),
    ),
  ),
);

CustomPaint _teardrop(WidgetTester tester) => tester.widget<CustomPaint>(
  find.byKey(WidgetKeys.markerTeardrop(_pubkey)),
);

void main() {
  const ringWidthFull = 3.0;
  const keyline = kMarkerKeyline;

  group('outline contrast (WCAG 1.4.11)', () {
    const alidadeSmooth = Color(0xFFF2F2F2);
    const alidadeDark = Color(0xFF1B1B1B);

    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    test('the keyline reads at 3:1 on the pale default basemap', () {
      expect(
        contrast(
          Color.alphaBlend(kMarkerKeyline, alidadeSmooth),
          alidadeSmooth,
        ),
        greaterThanOrEqualTo(3.0),
      );
    });

    test('the white ring reads at 3:1 on the dark basemap, where a dark '
        'keyline cannot', () {
      expect(contrast(_white, alidadeDark), greaterThanOrEqualTo(3.0));
    });
  });

  group('teardropPath', () {
    test('is a plain circle at nub <= 0.5', () {
      for (final nub in [0.0, 0.25, 0.5]) {
        final b = teardropPath(26, nub, 1.5).getBounds();
        expect(b.width, closeTo(52, 1e-9), reason: 'nub $nub');
        expect(b.height, closeTo(52, 1e-9), reason: 'nub $nub');
        expect(b.center, Offset.zero);
      }
    });

    test('the apex sits at radius + nub - apexInset', () {
      for (final nub in [3.0, 10.0, 22.0]) {
        final b = teardropPath(26, nub, 1.5).getBounds();
        expect(b.right, closeTo(26 + nub - 1.5, 1e-9), reason: 'nub $nub');
      }
    });

    test('the painted outer edge of the ring lands exactly on the tip', () {
      for (final d in [kDropletFullDiameter, 36.0, 20.0]) {
        final r = d / 2;
        final ring = markerRingWidthFor(d);
        const nub = 8.0;
        final apex = teardropPath(r, nub, ring / 2).getBounds().right;
        // Skia paths hold float32, so 1e-9 is below their resolution.
        expect(apex + ring / 2, closeTo(r + nub, 1e-5), reason: 'D $d');
      }
    });

    test('the flanks are concave, pulled toward the axis', () {
      const r = 26.0;
      const nub = 10.0;
      final path = teardropPath(r, nub, ringWidthFull / 2);
      const apexX = r + nub - ringWidthFull / 2;
      const cosT = r / apexX;
      final tangent = Offset(r * cosT, r * math.sqrt(1 - cosT * cosT));
      final metric = path.computeMetrics().first;
      var checked = 0;
      for (var o = 0.0; o < metric.length; o += 0.25) {
        final p = metric.getTangentForOffset(o)!.position;
        if (p.dy <= 1e-6 || p.dx <= tangent.dx + 0.5 || p.dx >= apexX - 0.5) {
          continue;
        }
        final straightY =
            tangent.dy * (apexX - p.dx) / (apexX - tangent.dx);
        expect(p.dy, lessThan(straightY - 0.2), reason: 'x ${p.dx}');
        checked++;
      }
      expect(checked, greaterThan(10), reason: 'the flank was sampled');
    });

    test('the apex half-angle at the on-screen tail is 20 to 35 degrees', () {
      final path = teardropPath(26, 10, ringWidthFull / 2);
      final v = path.computeMetrics().first.getTangentForOffset(0.05)!.vector;
      final halfAngle = math.atan2(v.dy.abs(), -v.dx) * 180 / math.pi;
      expect(halfAngle, inInclusiveRange(20, 35));
    });
  });

  group('MemberMarker shape', () {
    testWidgets('on-screen (nubLength 0) paints a plain circle', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final b = _paintMarker(tester).fill.path!.getBounds();
      expect(b.width, closeTo(52, 1e-3));
      expect(b.center.dx, closeTo(60, 1e-3));
    });

    testWidgets('grows an outward tail past the radius when nubLength > 0', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(nubLength: 8)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _paintMarker(tester).fill.path!.getBounds().right,
        greaterThan(60 + 29),
      );
    });

    testWidgets('paints a keyline, a palette gradient body and a white ring', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _paintMarker(tester);
      expect(
        rec.fill.hasShader,
        isTrue,
        reason: 'body is the palette gradient',
      );
      final strokes = rec.strokes;
      expect(strokes, hasLength(2));
      _expectColorMatches(strokes.first.color!, keyline);
      expect(strokes.first.width, ringWidthFull + 2);
      _expectColorMatches(strokes.last.color!, _white);
      expect(strokes.last.width, ringWidthFull);
    });

    testWidgets('ring and keyline are identical under light and dark themes', (
      tester,
    ) async {
      Future<List<_Op>> opsFor(ThemeData theme) async {
        await tester.pumpWidget(_wrap(_marker(nubLength: 10), theme: theme));
        await tester.pump(const Duration(milliseconds: 200));
        return _paintMarker(tester).ops;
      }

      final light = await opsFor(ThemeData.light());
      final dark = await opsFor(ThemeData.dark());
      expect(
        [for (final o in dark) o.color],
        [for (final o in light) o.color],
        reason: 'no ColorScheme colour reaches the canvas',
      );
      expect(
        [for (final o in dark) o.width],
        [for (final o in light) o.width],
      );
      final inks = [
        for (final o in light)
          if (o.kind == 'stroke') o.color!,
      ];
      expect(inks, hasLength(2));
      _expectColorMatches(inks.first, keyline);
      _expectColorMatches(inks.last, _white);
    });

    testWidgets('paints shadow, keyline, fill, image, then the white ring', (
      tester,
    ) async {
      final image = (await tester.runAsync(
        () => createTestImage(width: 4, height: 4),
      ))!;
      await tester.pumpWidget(
        _wrap(_marker(nubLength: 10, avatarImage: image)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _paintMarker(tester).kinds,
        ['shadow', 'stroke', 'fill', 'clip', 'image', 'stroke'],
      );
    });

    testWidgets('the paints matcher sees shadow, keyline, fill, ring in order '
        'and an upright canvas', (tester) async {
      await tester.pumpWidget(_wrap(_marker(nubLength: 10, angle: 0.6)));
      await tester.pump(const Duration(milliseconds: 200));
      final render = tester.renderObject(
        find.byKey(WidgetKeys.markerTeardrop(_pubkey)),
      );
      expect(
        render,
        paints
          ..shadow()
          ..path(color: keyline, style: PaintingStyle.stroke)
          ..path(style: PaintingStyle.fill)
          ..path(color: _white, style: PaintingStyle.stroke),
      );
      expect(render, isNot(paints..rotate()));
    });

    testWidgets('the tail is carried by the path; the canvas never rotates', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(_marker(nubLength: 10, angle: math.pi / 2)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _paintMarker(tester);
      expect(rec.kinds, isNot(contains('rotate')));
      final shadow = _tightBounds(rec.shadow.path!);
      expect(
        shadow.height,
        greaterThan(shadow.width + 5),
        reason: 'the shadow path is elongated along the tail (down)',
      );
    });

    testWidgets('the painted tip lands on the coordinate, at any angle', (
      tester,
    ) async {
      // Tail direction paired with the painted reach from the head centre
      // (footprint centre 60) along it.
      final cases = <(double, double Function(Rect))>[
        (0, (b) => b.right - 60),
        (math.pi / 2, (b) => b.bottom - 60),
        (-math.pi / 2, (b) => 60 - b.top),
        (math.pi, (b) => 60 - b.left),
      ];
      for (final (angle, reachOf) in cases) {
        await tester.pumpWidget(_wrap(_marker(nubLength: 10, angle: angle)));
        await tester.pump(const Duration(milliseconds: 200));
        final rec = _paintMarker(tester);
        final b = _tightBounds(rec.shadow.path!);
        final ringWidth = rec.strokes.last.width!;
        expect(
          reachOf(b) + ringWidth / 2,
          closeTo(36, 1e-4),
          reason: '$angle',
        );
      }
    });

    testWidgets('the gradient body is the palette of the public key', (
      tester,
    ) async {
      // Two keys one palette slot apart still paint, and repaint on change.
      await tester.pumpWidget(_wrap(_marker(publicKey: '00aa')));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _paintMarker(tester, '00aa');
      expect(rec.fill.hasShader, isTrue);
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

    test('footprint covers the longest tail, ring, keyline and shadow', () {
      expect(MemberMarker.footprintFor(52), 120);
      expect(MemberMarker.footprintFor(20), 88);
      expect(MemberMarker.footprintFor(0), greaterThanOrEqualTo(48));
    });
  });

  group('MemberMarker motion', () {
    testWidgets('uses a fade/scale appear transition by default', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      expect(_inMarker(find.byType(FadeTransition)), findsOneWidget);
      expect(_inMarker(find.byType(ScaleTransition)), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('scales about the tip of the tail', (tester) async {
      await tester.pumpWidget(
        _wrap(_marker(nubLength: 10, angle: math.pi / 2)),
      );
      final scale = tester.widget<ScaleTransition>(
        _inMarker(find.byType(ScaleTransition)),
      );
      // tip = 60 + (26 + 10) = 96 of 120 -> 96 / 120 * 2 - 1 = 0.6.
      expect(scale.alignment.x, closeTo(0, 1e-9));
      expect(scale.alignment.y, closeTo(0.6, 1e-9));
      await tester.pump(const Duration(milliseconds: 200));
    });

    testWidgets('reduce motion (MediaQuery) fades but never scales', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(), reduceMotion: true));
      expect(_inMarker(find.byType(ScaleTransition)), findsNothing);
      final fade = tester.widget<FadeTransition>(
        _inMarker(find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, 0.0, reason: 'a new marker starts hidden');
      await tester.pump(const Duration(milliseconds: 90));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 120));
      expect(fade.opacity.value, 1.0);
    });

    testWidgets('reduce motion (iOS engine flag) fades but never scales', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(_wrap(_marker()));
      expect(_inMarker(find.byType(ScaleTransition)), findsNothing);
      final fade = tester.widget<FadeTransition>(
        _inMarker(find.byType(FadeTransition)),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
    });

    testWidgets('the OS disable-animations flag does not collapse the fade', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(_wrap(_marker(), reduceMotion: true));
      final fade = tester.widget<FadeTransition>(
        _inMarker(find.byType(FadeTransition)),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(fade.opacity.value, inExclusiveRange(0, 1));
    });

    testWidgets('a reduce-motion flip is picked up on the next build', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_inMarker(find.byType(ScaleTransition)), findsOneWidget);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(_wrap(_marker(nubLength: 1)));
      expect(_inMarker(find.byType(ScaleTransition)), findsNothing);
    });

    testWidgets('reverses the appear transition and reports completion '
        'when exiting', (tester) async {
      var completed = false;
      void onDone() => completed = true;

      await tester.pumpWidget(_wrap(_marker(onExitComplete: onDone)));
      await tester.pump(const Duration(milliseconds: 200)); // appear settles

      final fade = tester.widget<FadeTransition>(
        _inMarker(find.byType(FadeTransition)),
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

    testWidgets('exit still fades and completes under reduce motion', (
      tester,
    ) async {
      var completed = false;
      void onDone() => completed = true;

      await tester.pumpWidget(
        _wrap(_marker(onExitComplete: onDone), reduceMotion: true),
      );
      await tester.pump(const Duration(milliseconds: 200));

      await tester.pumpWidget(
        _wrap(
          _marker(exiting: true, onExitComplete: onDone),
          reduceMotion: true,
        ),
      );
      await tester.pump(const Duration(milliseconds: 90));
      expect(completed, isFalse, reason: 'opacity is still falling');
      expect(_inMarker(find.byType(ScaleTransition)), findsNothing);
      await tester.pump(const Duration(milliseconds: 120));
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
        _inMarker(find.byType(FadeTransition)),
      );
      expect(fade.opacity.value, 0.0, reason: 'no frame to fade from → hidden');
      await tester.pump();
      expect(completed, isTrue, reason: 'completes via post-frame callback');
    });

    testWidgets('a marker born exiting hides and completes under reduce motion',
        (tester) async {
      var completed = false;
      await tester.pumpWidget(
        _wrap(
          _marker(exiting: true, onExitComplete: () => completed = true),
          reduceMotion: true,
        ),
      );
      expect(
        tester.widget<FadeTransition>(_inMarker(find.byType(FadeTransition)))
            .opacity
            .value,
        0.0,
      );
      await tester.pump();
      expect(completed, isTrue);
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
      expect(
        _semantics(tester).label,
        'Jane member marker, last seen 5 minutes ago',
      );
    });

    testWidgets('on-screen label omits "last seen" when fresh / null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(displayName: 'Jane')));
      expect(_semantics(tester).label, 'Jane member marker');
    });

    testWidgets('spoken age appears at the same 5-minute bound as the pill', (
      tester,
    ) async {
      // The two must not drift: a spoken age with no visible pill would tell a
      // screen-reader user a marker is stale while a sighted user sees nothing.
      await tester.pumpWidget(
        _wrap(
          _marker(
            displayName: 'Jane',
            lastSeen: DateTime.now().subtract(const Duration(minutes: 4)),
          ),
        ),
      );
      expect(_semantics(tester).label, 'Jane member marker');
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
      final s = _semantics(tester);
      expect(s.label, 'Member marker');
      expect(s.label, isNot(contains('JD')),
          reason: 'a no-display-name marker must not speak its initials');
    });

    testWidgets('off-screen label is directional', (tester) async {
      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', offScreen: true, nubLength: 8)),
      );
      expect(
        _semantics(tester).label,
        'Jane is off-screen to the east, tap to view',
      );
    });

    testWidgets('the spoken direction is the bearing, never the tail angle', (
      tester,
    ) async {
      // A member due east just past the edge: the tail leans ~35 degrees
      // south-east, the bearing is exactly east.
      await tester.pumpWidget(
        _wrap(
          _marker(
            displayName: 'Jane',
            offScreen: true,
            nubLength: 8,
            angle: 35 * math.pi / 180,
          ),
        ),
      );
      expect(
        _semantics(tester).label,
        'Jane is off-screen to the east, tap to view',
      );

      // And the reverse: a southern bearing is spoken even with an east tail.
      await tester.pumpWidget(
        _wrap(
          _marker(
            displayName: 'Jane',
            offScreen: true,
            nubLength: 8,
            bearing: math.pi / 2,
          ),
        ),
      );
      expect(
        _semantics(tester).label,
        'Jane is off-screen to the south, tap to view',
      );
    });

    testWidgets('off-screen label is localized (compass bearing unchanged)', (
      tester,
    ) async {
      // Same eastward bearing, Arabic locale: the direction WORD localizes
      // ("east" -> "الشرق") while the geographic bearing is unchanged. Proves
      // the bearing -> CompassDirection -> l10n wiring and that geography is
      // not mirrored — only translated.
      await tester.pumpWidget(
        _wrap(
          _marker(displayName: 'Jane', offScreen: true, nubLength: 8),
          locale: const Locale('ar'),
        ),
      );
      final s = _semantics(tester);
      expect(s.label, contains('الشرق')); // east
      expect(s.label, contains('خارج الشاشة')); // off-screen
      expect(s.label, isNot(contains('off-screen'))); // not the English string
    });

    testWidgets('the node is the tap-sized box, not the 120 px footprint', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(onTap: () {})));
      expect(_semantics(tester).rect.size, const Size(52, 52));

      await tester.pumpWidget(
        _wrap(_marker(diameter: 20, offScreen: true, nubLength: 8)),
      );
      expect(
        _semantics(tester).rect.size,
        const Size(48, 48),
        reason: 'a small bead still has a 48 dp node, even with no onTap',
      );
    });

    testWidgets('the node follows the inward tapOffset', (tester) async {
      await tester.pumpWidget(
        _wrap(
          _marker(
            diameter: 20,
            offScreen: true,
            nubLength: 8,
            tapOffset: const Offset(-10, 4),
          ),
        ),
      );
      final node = tester.getCenter(
        find.byKey(WidgetKeys.markerSemantics(_pubkey)),
      );
      final head = tester.getCenter(find.byType(MemberMarker));
      expect(node.dx, closeTo(head.dx - 10, 1e-9));
      expect(node.dy, closeTo(head.dy + 4, 1e-9));
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

    testWidgets('the age pill adds no semantics node of its own', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _wrap(
          _marker(
            displayName: 'Jane',
            lastSeen: DateTime.now().subtract(const Duration(minutes: 5)),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.bySemanticsLabel('5m'), findsNothing);
      handle.dispose();
    });
  });

  group('MemberMarker age pill', () {
    testWidgets('shows the pill for an on-screen marker at age >= 5 min', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('5m'), findsOneWidget);
    });

    testWidgets('stays untagged below 5 minutes', (tester) async {
      // A healthy peer publishes every ~2 min (up to 168 s under jitter), so
      // a 4-minute-old fix is an ON-TIME one that happened to arrive late.
      // Tagging it is exactly the noise the 5-minute bound exists to prevent.
      // Four minutes rather than 4:59 leaves a full minute of slack, so a slow
      // test machine cannot tip the age over the bound.
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 4));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen)));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('m'), findsNothing);
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

    testWidgets('buckets a clock-ahead peer as fresh, never as a future age', (
      tester,
    ) async {
      // A peer whose clock runs fast stamps its fix in the future. Its age is
      // NEGATIVE, and it must land in the same untagged bucket as a fresh fix
      // — a "-59m" pill would be a wall-clock reading of another person's
      // device presented as staleness.
      final ahead = DateTime.now().add(const Duration(minutes: 59));
      await tester.pumpWidget(
        _wrap(_marker(displayName: 'Jane', lastSeen: ahead)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('m'), findsNothing);
      expect(find.textContaining('-'), findsNothing);
      expect(
        _semantics(tester).label,
        'Jane member marker',
        reason: 'a screen reader must not announce a negative age either',
      );
    });

    testWidgets('is constant white ink with no border, whatever the theme', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await tester.pumpWidget(
          _wrap(_marker(lastSeen: lastSeen), theme: theme),
        );
        await tester.pump(const Duration(milliseconds: 200));
        final pill = tester.widget<Container>(
          find
              .ancestor(of: find.text('5m'), matching: find.byType(Container))
              .first,
        );
        final decoration = pill.decoration! as ShapeDecoration;
        expect(decoration.color, _white);
        final shape = decoration.shape as StadiumBorder;
        expect(shape.side, BorderSide.none);
        final shadow = decoration.shadows!.single;
        _expectColorMatches(shadow.color, Colors.black.withValues(alpha: 0.25));
        expect(shadow.blurRadius, 4);
        expect(shadow.offset, const Offset(0, 2));

        final style = tester.widget<Text>(find.text('5m')).style!;
        expect(style.color, const Color(0xFF525252));
        expect(style.fontSize, 11);
        expect(style.fontWeight, FontWeight.w600);
        expect(style.height, 1);
        expect(
          style.fontFeatures,
          contains(const ui.FontFeature.tabularFigures()),
        );
      }
    });

    testWidgets('stays inside the safe rect with the head at the right inset', (
      tester,
    ) async {
      const size = Size(400, 400);
      // The layer holds a full head 30 px (radius + margin) from the edge.
      const head = Offset(400 - 30, 200);
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(
        _placed(_marker(lastSeen: lastSeen), head, size),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final pillRect = tester.getRect(
        find
            .ancestor(of: find.text('5m'), matching: find.byType(Container))
            .first,
      );
      expect(pillRect.right, lessThanOrEqualTo(size.width));
    });

    testWidgets('the pill offset and the tail are the same under RTL', (
      tester,
    ) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      final marker = _marker(
        lastSeen: lastSeen,
        nubLength: 10,
        angle: math.pi / 3,
      );
      final pill = find.ancestor(
        of: find.text('5m'),
        matching: find.byType(Container),
      );

      await tester.pumpWidget(_wrap(marker));
      await tester.pump(const Duration(milliseconds: 200));
      final ltrPill = tester.getRect(pill.first);
      final ltrTail = _tightBounds(_paintMarker(tester).fill.path!);

      await tester.pumpWidget(
        _wrap(Directionality(textDirection: TextDirection.rtl, child: marker)),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.getRect(pill.first), ltrPill);
      expect(_tightBounds(_paintMarker(tester).fill.path!), ltrTail);
    });

    testWidgets('sits below the head when the tail points up', (tester) async {
      final lastSeen = DateTime.now().subtract(const Duration(minutes: 5));
      await tester.pumpWidget(_wrap(_marker(lastSeen: lastSeen)));
      await tester.pump(const Duration(milliseconds: 200));
      final above = tester.getCenter(find.text('5m')).dy;
      await tester.pumpWidget(
        _wrap(_marker(lastSeen: lastSeen, nubLength: 8, angle: -math.pi / 2)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final below = tester.getCenter(find.text('5m')).dy;
      final head = tester.getCenter(find.byType(MemberMarker)).dy;
      expect(above, lessThan(head));
      expect(below, greaterThan(head));
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
      expect(_inMarker(find.byType(GestureDetector)), findsNothing);
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
      final tapRect = tester.getRect(_inMarker(find.byType(GestureDetector)));
      expect(tapRect.center.dx, closeTo(markerRect.center.dx - 10, 0.5));
      expect(tapRect.width, greaterThanOrEqualTo(48));
    });
  });

  group('MemberMarker press feedback', () {
    double pressScale(WidgetTester tester) => tester
        .widget<ScaleTransition>(
          find.descendant(
            of: find.byType(AnimatedScale),
            matching: find.byType(ScaleTransition),
          ),
        )
        .scale
        .value;

    Future<void> settle(WidgetTester tester) =>
        tester.pump(const Duration(milliseconds: 200));

    testWidgets('shrinks to 0.94 over 100 ms while pressed and returns to 1 '
        'over 150 ms on release', (tester) async {
      await tester.pumpWidget(_wrap(_marker(onTap: () {})));
      await settle(tester);
      expect(pressScale(tester), 1.0);

      final g = await tester.startGesture(
        tester.getCenter(find.byType(MemberMarker)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pressScale(tester), closeTo(0.94, 1e-9));

      await g.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      expect(pressScale(tester), inExclusiveRange(0.94, 1.0));
      await tester.pump(const Duration(milliseconds: 75));
      expect(pressScale(tester), closeTo(1.0, 1e-9));
    });

    testWidgets('a cancelled press releases', (tester) async {
      await tester.pumpWidget(_wrap(_marker(onTap: () {})));
      await settle(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(MemberMarker)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pressScale(tester), closeTo(0.94, 1e-9));
      await g.cancel();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(pressScale(tester), closeTo(1.0, 1e-9));
    });

    testWidgets('losing onTap under a held finger does not stick the press', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker(onTap: () {})));
      await settle(tester);
      final g = await tester.startGesture(
        tester.getCenter(find.byType(MemberMarker)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(pressScale(tester), closeTo(0.94, 1e-9));

      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpWidget(_wrap(_marker(onTap: () {})));
      await tester.pump(const Duration(milliseconds: 150));

      expect(pressScale(tester), closeTo(1.0, 1e-9));
      await g.cancel();
    });

    testWidgets('scales about the tip alignment', (tester) async {
      await tester.pumpWidget(
        _wrap(_marker(nubLength: 10, angle: math.pi / 2, onTap: () {})),
      );
      final scale = tester.widget<AnimatedScale>(find.byType(AnimatedScale));
      expect(scale.alignment.x, closeTo(0, 1e-9));
      expect(scale.alignment.y, closeTo(0.6, 1e-9));
      await settle(tester);
    });

    for (final flag in ['MediaQuery', 'engine']) {
      testWidgets('is instant under reduce motion ($flag)', (tester) async {
        if (flag == 'engine') {
          tester.platformDispatcher.accessibilityFeaturesTestValue =
              const FakeAccessibilityFeatures(reduceMotion: true);
          addTearDown(
            tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
          );
        }
        await tester.pumpWidget(
          _wrap(_marker(onTap: () {}), reduceMotion: flag == 'MediaQuery'),
        );
        await settle(tester);
        final g = await tester.startGesture(
          tester.getCenter(find.byType(MemberMarker)),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(pressScale(tester), closeTo(0.94, 1e-9));
        await g.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 1));
        expect(pressScale(tester), closeTo(1.0, 1e-9));
      });
    }

    testWidgets('a marker with no onTap has no press path', (tester) async {
      await tester.pumpWidget(_wrap(_marker()));
      await settle(tester);
      expect(_inMarker(find.byType(AnimatedScale)), findsNothing);
    });

    group('haptic', () {
      late List<String> haptics;

      setUp(() {
        haptics = [];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String);
          }
          return null;
        });
      });

      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      testWidgets('an on-screen tap gives exactly one light impact', (
        tester,
      ) async {
        var taps = 0;
        await tester.pumpWidget(_wrap(_marker(onTap: () => taps++)));
        await settle(tester);
        await tester.tap(find.byType(MemberMarker));
        await tester.pump();
        expect(taps, 1);
        expect(haptics, ['HapticFeedbackType.lightImpact']);
      });

      testWidgets('an off-screen tap leaves the haptic to the focus helper', (
        tester,
      ) async {
        var taps = 0;
        await tester.pumpWidget(
          _wrap(_marker(offScreen: true, onTap: () => taps++)),
        );
        await settle(tester);
        await tester.tap(find.byType(MemberMarker));
        await tester.pump();
        expect(taps, 1);
        expect(haptics, isEmpty);
      });

      testWidgets('a screen-reader activation taps once with one light '
          'impact', (tester) async {
        final handle = tester.ensureSemantics();
        var taps = 0;
        await tester.pumpWidget(_wrap(_marker(onTap: () => taps++)));
        await settle(tester);

        final node = _semantics(tester);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        // The gesture detector's own tap node would be a second stop.
        expect(node.childrenCount, 0);
        node.owner!.performAction(
          node.id,
          SemanticsAction.tap,
        );
        await tester.pump();

        expect(taps, 1);
        expect(haptics, ['HapticFeedbackType.lightImpact']);
        handle.dispose();
      });

      testWidgets('an off-screen screen-reader activation taps once with no '
          'haptic of its own', (tester) async {
        final handle = tester.ensureSemantics();
        var taps = 0;
        await tester.pumpWidget(
          _wrap(_marker(offScreen: true, onTap: () => taps++)),
        );
        await settle(tester);

        final node = _semantics(tester);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
        // The gesture detector's own tap node would be a second stop.
        expect(node.childrenCount, 0);
        node.owner!.performAction(
          node.id,
          SemanticsAction.tap,
        );
        await tester.pump();

        expect(taps, 1);
        expect(haptics, isEmpty);
        handle.dispose();
      });

      testWidgets('a marker with no onTap gives none', (tester) async {
        await tester.pumpWidget(_wrap(_marker()));
        await settle(tester);
        await tester.tap(find.byType(MemberMarker), warnIfMissed: false);
        await tester.pump();
        expect(haptics, isEmpty);
      });
    });
  });

  group('MemberMarker avatar', () {
    testWidgets('paints initials glyph when avatarImage is null', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(_marker()));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _paintMarker(tester);
      // No image was drawn; the fill path (body) is present.
      expect(rec.drawnImage, isNull,
          reason: 'null avatarImage must not call drawImageRect');
      expect(rec.kinds, contains('fill'),
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
      await tester.pumpWidget(_wrap(_marker(avatarImage: testImage)));
      await tester.pump(const Duration(milliseconds: 200));
      final rec = _paintMarker(tester);
      // The image was drawn and the canvas was clipped.
      expect(rec.drawnImage, same(testImage),
          reason: 'supplied avatarImage must be drawn via drawImageRect');
      expect(rec.kinds, contains('clip'),
          reason: 'canvas must be clipped to the head circle');
      // The body fill (shadow + keyline + fill) is still present.
      expect(rec.kinds, contains('fill'),
          reason: 'body fill must still be drawn');
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
      await tester.pumpWidget(_wrap(_marker(avatarImage: img1)));
      await tester.pump(const Duration(milliseconds: 200));
      final painter1 = _teardrop(tester).painter!;

      await tester.pumpWidget(_wrap(_marker(avatarImage: img2)));
      await tester.pump();
      final painter2 = _teardrop(tester).painter!;

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
      await tester.pumpWidget(_wrap(_marker(avatarImage: img)));
      await tester.pump(const Duration(milliseconds: 200));
      // Same painter instance — shouldRepaint(same_painter) must be false.
      final p = _teardrop(tester).painter!;
      expect(p.shouldRepaint(p), isFalse);
    });
  });

  group('MemberMarker repaint', () {
    Future<CustomPainter> painterOf(
      WidgetTester tester,
      MemberMarker marker, {
      double textScale = 1,
    }) async {
      await tester.pumpWidget(_wrap(marker, textScale: textScale));
      await tester.pump(const Duration(milliseconds: 200));
      return tester
          .widget<CustomPaint>(
            find.byKey(WidgetKeys.markerTeardrop(marker.publicKey)),
          )
          .painter!;
    }

    testWidgets('repaints for every painted field and only for those', (
      tester,
    ) async {
      final image = (await tester.runAsync(
        () => createTestImage(width: 4, height: 4),
      ))!;
      // 'deadbeef' is palette slot 6; '00aa' is slot 0.
      final base = await painterOf(tester, _marker(nubLength: 6));
      final same = await painterOf(tester, _marker(nubLength: 6));
      expect(same.shouldRepaint(base), isFalse, reason: 'identical inputs');

      final variants = <String, MemberMarker>{
        'diameter': _marker(nubLength: 6, diameter: 40),
        'nubLength': _marker(nubLength: 7),
        'angle': _marker(nubLength: 6, angle: 1),
        'glyph': _marker(nubLength: 6, initials: 'XY'),
        'avatarImage': _marker(nubLength: 6, avatarImage: image),
      };
      for (final entry in variants.entries) {
        final next = await painterOf(tester, entry.value);
        expect(next.shouldRepaint(base), isTrue, reason: entry.key);
      }

      final other = await painterOf(
        tester,
        _marker(nubLength: 6, publicKey: '00aa'),
      );
      expect(other.shouldRepaint(base), isTrue, reason: 'palette');

      final scaled = await painterOf(
        tester,
        _marker(nubLength: 6),
        textScale: 1.2,
      );
      expect(scaled.shouldRepaint(base), isTrue, reason: 'textScaler');
    });
  });
}
