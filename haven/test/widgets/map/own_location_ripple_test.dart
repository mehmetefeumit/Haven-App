// The ripple out of the user's own dot when their own location is handed to
// the Bluetooth mesh (`docs/BLUETOOTH_MESH_AURA_DESIGN.md` §3, §4, §7).
//
//  * a hand-off to a mesh that runs with a phone linked ripples once, from
//    the dot, wherever the map has moved to; a hand-off while one runs is
//    dropped;
//  * mesh off, paused or with no phone linked ripples nothing;
//  * at rest the layer is the dot alone and nothing is scheduled, and a
//    frame of the ripple repaints no other layer of the map;
//  * reduced motion gets a halo that does not grow;
//  * it takes no touch, adds no semantics, and logs nothing.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/widgets/map/own_location_ripple.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';
import 'package:latlong2/latlong.dart';

import '../../helpers/fake_mesh.dart';
import '../../helpers/log_capture.dart';

const _here = LatLng(51.5, -0.1);

const Key _member = ValueKey('member');

final Finder _ripple = find.byType(OwnLocationRipple);
final Finder _dot = find.byType(UserLocationMarker);

class _Map {
  final mesh = FakeMeshService();
  final radio = FakeMeshRadio();
  final controller = MapController();
  int memberTaps = 0;
  int underPaints = 0;

  Future<void> pump(
    WidgetTester tester, {
    bool running = true,
    bool linked = true,
    bool disableAnimations = false,
    bool dark = false,
    LatLng point = _here,
  }) async {
    mesh.statsAnswer = meshState(on: true, linked: linked, onForMs: 3600000);
    radio.statusAnswer = radioStatus(
      running ? MeshRadioState.running : MeshRadioState.paused,
      wanted: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          meshServiceProvider.overrideWithValue(mesh),
          meshRadioProvider.overrideWithValue(radio),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: Scaffold(
              body: FlutterMap(
                mapController: controller,
                options: const MapOptions(
                  initialCenter: _here,
                  initialZoom: 15,
                ),
                children: [
                  // Other layers of the map, under the user's own: one that
                  // paints, as the tiles do, and a member's marker standing
                  // where the ripple will pass.
                  CustomPaint(painter: _Counting(() => underPaints++)),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: point,
                        width: 24,
                        height: 24,
                        alignment: const Alignment(4, 0),
                        child: GestureDetector(
                          key: _member,
                          behavior: HitTestBehavior.opaque,
                          onTap: () => memberTaps++,
                        ),
                      ),
                    ],
                  ),
                  OwnLocationLayer(point: point, darkBasemap: dark),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // The engine and the radio answer.
    ProviderScope.containerOf(tester.element(_dot)).read(meshPhaseProvider);
    await tester.pump();
    await tester.pump();
  }

  /// A publish pass handed the own location over.
  Future<void> handOff(WidgetTester tester) async {
    final container = ProviderScope.containerOf(tester.element(_dot));
    await container.read(meshHandOffProvider.notifier).handedOff();
    await tester.pump();
  }
}

/// The ripple as painted now: the luminance of its colour and the strongest
/// alpha anywhere in it.
Future<(double, double)> _ring(WidgetTester tester) async {
  final paint = tester.widget<CustomPaint>(
    find.descendant(of: _ripple, matching: find.byType(CustomPaint)),
  );
  const side = kOwnLocationRippleRadius * 2;
  final recorder = ui.PictureRecorder();
  paint.painter!.paint(Canvas(recorder), const Size.square(side));
  final picture = recorder.endRecording();
  final rgba = (await tester.runAsync(() async {
    final image = await picture.toImage(side.toInt(), side.toInt());
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return bytes;
  }))!;
  picture.dispose();
  var strongest = 0;
  var at = 0;
  for (var i = 0; i < rgba.lengthInBytes; i += 4) {
    if (rgba.getUint8(i + 3) > strongest) {
      strongest = rgba.getUint8(i + 3);
      at = i;
    }
  }
  final colour = Color.fromARGB(
    255,
    rgba.getUint8(at),
    rgba.getUint8(at + 1),
    rgba.getUint8(at + 2),
  );
  return (colour.computeLuminance(), strongest.toDouble());
}

void _expectAtRest(WidgetTester tester) {
  expect(_ripple, findsNothing);
  expect(tester.binding.hasScheduledFrame, isFalse);
  expect(tester.binding.transientCallbackCount, 0);
}

Duration get _over =>
    kOwnLocationRippleDuration + const Duration(milliseconds: 1);

void main() {
  testWidgets('at rest the layer is the dot alone, and nothing is '
      'scheduled', (tester) async {
    final map = _Map();
    await map.pump(tester);

    expect(_dot, findsOneWidget);
    expect(
      tester
          .widget<MarkerLayer>(
            find.ancestor(of: _dot, matching: find.byType(MarkerLayer)),
          )
          .markers,
      hasLength(1),
    );
    _expectAtRest(tester);
  });

  testWidgets('a hand-off ripples once out of the dot, and then the layer is '
      'the dot alone again', (tester) async {
    final map = _Map();
    await map.pump(tester);
    final dot = tester.element(_dot);

    await map.handOff(tester);

    expect(_ripple, findsOneWidget);
    expect(tester.getCenter(_ripple), tester.getCenter(_dot));
    expect(tester.getSize(_ripple), const Size.square(144));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    // The dot is the dot it was: a screen reader on it is not thrown off by
    // the ripple arriving ahead of it, nor by its leaving.
    expect(tester.element(_dot), same(dot));

    await tester.pump(_over);
    await tester.pump();

    expect(tester.element(_dot), same(dot));
    _expectAtRest(tester);
  });

  testWidgets('the ripple stays on the dot through a move, a zoom and a '
      'rotation of the map, and the dot is not remounted', (tester) async {
    final map = _Map();
    await map.pump(tester);
    await map.handOff(tester);
    final dot = tester.element(_dot);
    final start = tester.getCenter(_dot);

    map.controller.move(const LatLng(51.503, -0.104), 16);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getCenter(_dot), isNot(start));
    expect(tester.getCenter(_ripple), tester.getCenter(_dot));

    map.controller.rotate(40);
    await tester.pump(const Duration(milliseconds: 100));
    final ripple = tester.getCenter(_ripple);
    final centre = tester.getCenter(_dot);
    expect((ripple - centre).distance, lessThan(0.01));
    expect(tester.element(_dot), same(dot));
    await tester.pump(_over);
    await tester.pump();
  });

  testWidgets('a hand-off while a ripple runs is dropped: the one running '
      'ends when it would have', (tester) async {
    final map = _Map();
    await map.pump(tester);
    await map.handOff(tester);
    await tester.pump(const Duration(milliseconds: 1000));

    await map.handOff(tester);
    await tester.pump(_over - const Duration(milliseconds: 1000));
    await tester.pump();

    _expectAtRest(tester);
  });

  testWidgets('the next hand-off after a ripple has ended ripples '
      'again', (tester) async {
    final map = _Map();
    await map.pump(tester);
    await map.handOff(tester);
    await tester.pump(_over);
    await tester.pump();
    expect(_ripple, findsNothing);

    await map.handOff(tester);

    expect(_ripple, findsOneWidget);
    await tester.pump(_over);
    await tester.pump();
  });

  testWidgets('a hand-off told while the app is away is dropped: no ripple '
      'waits for the return', (tester) async {
    final map = _Map();
    await map.pump(tester);
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );

    await map.handOff(tester);
    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    _expectAtRest(tester);
    // The next one, in front, ripples.
    await map.handOff(tester);
    expect(_ripple, findsOneWidget);
    await tester.pump(_over);
    await tester.pump();
  });

  testWidgets('on a dark map the ripple is a lighter blue, and more of it: '
      'the blue of the light map is lost on that ground', (tester) async {
    final rings = <bool, (double, double)>{};
    for (final dark in [false, true]) {
      final map = _Map();
      await map.pump(tester, dark: dark);
      await map.handOff(tester);
      await tester.pump(const Duration(milliseconds: 400));
      final picture = await _ring(tester);
      rings[dark] = picture;
      await tester.pump(_over);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    }

    final (lightLuminance, lightAlpha) = rings[false]!;
    final (darkLuminance, darkAlpha) = rings[true]!;
    expect(darkLuminance, greaterThan(lightLuminance * 1.5));
    expect(darkAlpha, greaterThan(lightAlpha));
    // Soft on either: never more than half there.
    expect(darkAlpha, lessThanOrEqualTo(0.5 * 255));
  });

  testWidgets('with mesh paused, or no phone linked, a hand-off ripples '
      'nothing', (tester) async {
    for (final (running, linked) in [(false, true), (true, false)]) {
      final map = _Map();
      await map.pump(tester, running: running, linked: linked);

      await map.handOff(tester);

      _expectAtRest(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a frame of the ripple repaints no other layer of the map and '
      'rebuilds nothing', (tester) async {
    final map = _Map();
    await map.pump(tester);
    await map.handOff(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final painted = map.underPaints;
    final widget = tester.widget(_ripple);
    final layer = tester.renderObject<RenderRepaintBoundary>(
      find.descendant(of: _ripple, matching: find.byType(RepaintBoundary)),
    );
    final layerPaints = layer.debugAsymmetricPaintCount;

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    // Each frame painted the ripple again, in its own layer and no other.
    expect(layer.debugAsymmetricPaintCount, layerPaints + 10);
    expect(map.underPaints, painted);
    expect(tester.widget(_ripple), same(widget));
    await tester.pump(_over);
    await tester.pump();
  });

  testWidgets('the ripple widens and fades; with motion reduced it is a halo '
      'of one size', (tester) async {
    for (final still in [false, true]) {
      final map = _Map();
      await map.pump(tester, disableAnimations: still);
      await map.handOff(tester);
      final paint = find.descendant(
        of: _ripple,
        matching: find.byType(CustomPaint),
      );
      final radii = <double>[];
      bool record(Symbol method, List<dynamic> arguments) {
        if (method == #drawCircle) radii.add(arguments[1] as double);
        if (method == #saveLayer) throw StateError('a saveLayer');
        return true;
      }

      final seen = <double>{};
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 150));
        radii.clear();
        expect(paint, paints..everything(record));
        expect(radii, isNotEmpty);
        // The outermost ring at this frame.
        seen.add(radii.reduce((a, b) => a > b ? a : b));
      }

      if (still) {
        expect(seen, hasLength(1), reason: 'still');
      } else {
        expect(seen.length, greaterThan(4), reason: 'moving');
        expect(seen.last, greaterThan(seen.first));
      }
      expect(
        seen.every((radius) => radius <= kOwnLocationRippleRadius),
        isTrue,
      );
      await tester.pump(_over);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets("a tap on the ripple reaches the member's marker under "
      'it', (tester) async {
    final map = _Map();
    await map.pump(tester);
    await map.handOff(tester);
    await tester.pump(const Duration(milliseconds: 200));
    final member = tester.getCenter(find.byKey(_member));
    // Premise: the marker is inside the ripple, clear of the dot.
    expect(tester.getRect(_ripple).contains(member), isTrue);
    expect(tester.getRect(_dot).contains(member), isFalse);

    await tester.tapAt(member);

    expect(map.memberTaps, 1);
    await tester.pump(_over);
    await tester.pump();
  });

  testWidgets('the ripple adds nothing to the semantics tree, and nothing is '
      'logged when it fires', (tester) async {
    final handle = tester.ensureSemantics();
    final map = _Map();
    await map.pump(tester);
    int nodes() {
      var count = 0;
      void visit(SemanticsNode node) {
        count++;
        node.visitChildren((child) {
          visit(child);
          return true;
        });
      }

      visit(
        tester
            .binding
            .renderViews
            .first
            .owner!
            .semanticsOwner!
            .rootSemanticsNode!,
      );
      return count;
    }

    final atRest = nodes();
    final logs = LogCapture();

    await map.handOff(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(_ripple, findsOneWidget);
    expect(nodes(), atRest);
    await tester.pump(_over);
    await tester.pump();
    logs.restore();
    expect(logs.lines, isEmpty);
    handle.dispose();
  });
}

class _Counting extends CustomPainter {
  _Counting(this.onPaint);

  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) => onPaint();

  @override
  bool shouldRepaint(_Counting old) => false;
}
