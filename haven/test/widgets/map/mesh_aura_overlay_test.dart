// The mesh aura (`docs/BLUETOOTH_MESH_AURA_DESIGN.md`): what a user would
// notice breaking.
//
//  * when mesh starts running a wave leaves the mesh button and reaches the
//    edges of the window, whatever its size, and leaves a blue hue round
//    them for as long as mesh runs; the hue goes when mesh stops;
//  * mesh found running is the hue with no wave;
//  * reduced motion gets the hue and no travelling wave;
//  * at rest nothing is scheduled, and a frame of the wave builds nothing,
//    lays out nothing and repaints nothing under it;
//  * it takes no touch and has no semantics.
//
// Pixels are read out of the painter's own picture, with tolerances; no
// golden file.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';
import 'package:haven/src/widgets/map/mesh_aura_overlay.dart';

import '../../helpers/fake_mesh.dart';

const Size _phone = Size(390, 844);

final Finder _paint = find.descendant(
  of: find.byType(MeshAuraOverlay),
  matching: find.byType(CustomPaint),
);

/// The aura as it is painted now.
class _Picture {
  _Picture(this._rgba, this.size);

  final ByteData? _rgba;
  final Size size;

  /// The alpha at [at], 0 to 255.
  int alpha(Offset at) {
    final rgba = _rgba;
    if (rgba == null) return 0;
    final x = at.dx.floor().clamp(0, size.width.ceil() - 1);
    final y = at.dy.floor().clamp(0, size.height.ceil() - 1);
    return rgba.getUint8((y * size.width.ceil() + x) * 4 + 3);
  }

  /// Whether [at] is tinted blue.
  bool blue(Offset at) {
    final rgba = _rgba;
    if (rgba == null) return false;
    final x = at.dx.floor().clamp(0, size.width.ceil() - 1);
    final y = at.dy.floor().clamp(0, size.height.ceil() - 1);
    final i = (y * size.width.ceil() + x) * 4;
    return rgba.getUint8(i + 3) > 0 && rgba.getUint8(i + 2) > rgba.getUint8(i);
  }

  /// The middle of each edge and each corner, just inside the window.
  List<Offset> get rim => [
    Offset(size.width / 2, 1),
    Offset(size.width / 2, size.height - 1),
    Offset(1, size.height / 2),
    Offset(size.width - 1, size.height / 2),
    const Offset(1, 1),
    Offset(size.width - 1, 1),
    Offset(1, size.height - 1),
    Offset(size.width - 1, size.height - 1),
  ];

  Offset get centre => size.center(Offset.zero);
}

Future<_Picture> _picture(WidgetTester tester) async {
  final size = tester.getSize(find.byType(MeshAuraOverlay));
  if (_paint.evaluate().isEmpty) return _Picture(null, size);
  final recorder = ui.PictureRecorder();
  tester.widget<CustomPaint>(_paint).painter!.paint(Canvas(recorder), size);
  final picture = recorder.endRecording();
  final rgba = await tester.runAsync(() async {
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    image.dispose();
    return bytes;
  });
  picture.dispose();
  return _Picture(rgba, size);
}

void _window(WidgetTester tester, Size size) {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pump(
  WidgetTester tester, {
  required bool running,
  Size size = _phone,
  EdgeInsets viewPadding = EdgeInsets.zero,
  bool disableAnimations = false,
  Widget? under,
}) {
  _window(tester, size);
  return tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: size,
        viewPadding: viewPadding,
        disableAnimations: disableAnimations,
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            ?under,
            Positioned.fill(child: MeshAuraOverlay(running: running)),
          ],
        ),
      ),
    ),
  );
}

/// Off, then on: the first frame of the wave is the one pumped here.
Future<void> _turnOn(
  WidgetTester tester, {
  Size size = _phone,
  EdgeInsets viewPadding = EdgeInsets.zero,
  bool disableAnimations = false,
  Widget? under,
}) async {
  await _pump(
    tester,
    running: false,
    size: size,
    viewPadding: viewPadding,
    disableAnimations: disableAnimations,
    under: under,
  );
  await _pump(
    tester,
    running: true,
    size: size,
    viewPadding: viewPadding,
    disableAnimations: disableAnimations,
    under: under,
  );
  await tester.pump();
}

Duration _waveOf(Size size, [EdgeInsets viewPadding = EdgeInsets.zero]) =>
    waveDuration(waveReach(size, meshButtonRect(size, viewPadding).center));

/// The first frame past [duration]: the one an animation of that length
/// ends on.
Duration _past(Duration duration) => duration + const Duration(milliseconds: 1);

void _expectAtRest(WidgetTester tester) {
  expect(tester.binding.hasScheduledFrame, isFalse);
  expect(tester.binding.transientCallbackCount, 0);
}

void _expectHue(_Picture picture, {String? reason}) {
  for (final at in picture.rim) {
    expect(picture.blue(at), isTrue, reason: '$at ${reason ?? ''}');
    // A glow, not a line: about a third of the blue at the very edge.
    expect(
      picture.alpha(at),
      inInclusiveRange(60, 100),
      reason: '$at ${reason ?? ''}',
    );
  }
  // And it thins quickly inward: half of the edge's blue by a third of the
  // hue's width, next to none by two thirds.
  final width = hueWidth(picture.size);
  final middle = picture.size.width / 2;
  expect(
    picture.alpha(Offset(middle, width * 0.3)),
    inInclusiveRange(35, 55),
    reason: reason,
  );
  expect(
    picture.alpha(Offset(middle, width * 0.65)),
    inInclusiveRange(5, 20),
    reason: reason,
  );
  expect(picture.alpha(picture.centre), 0, reason: reason);
}

void main() {
  testWidgets('off, it builds nothing and schedules nothing', (tester) async {
    await _pump(tester, running: false);

    expect(_paint, findsNothing);
    _expectAtRest(tester);
  });

  testWidgets('mesh found running is the hue round the edges, with no wave '
      'and nothing scheduled', (tester) async {
    await _pump(tester, running: true);

    _expectHue(await _picture(tester));
    _expectAtRest(tester);
  });

  testWidgets('turning on starts a wave at the mesh button: at half time its '
      'front is where the design puts it', (tester) async {
    await _turnOn(tester);
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    // Nothing yet: the wave starts at the button, the hue behind it.
    final first = await _picture(tester);
    expect(first.alpha(first.centre), 0);
    expect(first.alpha(const Offset(1, 1)), 0);

    final duration = _waveOf(_phone);
    const elapsed = Duration(milliseconds: 496);
    await tester.pump(elapsed);
    final picture = await _picture(tester);

    final origin = meshButtonRect(_phone, EdgeInsets.zero).center;
    final reach = waveReach(_phone, origin);
    final band = waveBand(reach);
    final t = elapsed.inMicroseconds / duration.inMicroseconds;
    final front = Curves.easeOutSine.transform(t) * (reach + band);
    // Towards the corner the wave has farthest to go.
    final away = Offset(_phone.width, 0) - origin;
    Offset at(double distance) => origin + away / away.distance * distance;

    // Its peak, a little behind the front; the wash it leaves; nothing ahead.
    expect(picture.blue(at(front - 0.35 * band)), isTrue);
    expect(picture.alpha(at(front - 0.35 * band)), inInclusiveRange(40, 64));
    expect(picture.alpha(at(front - band - 20)), inInclusiveRange(8, 24));
    expect(picture.alpha(at(front + 8)), 0);
    // The edge the wave has not reached has no hue yet.
    expect(picture.alpha(Offset(_phone.width - 1, 1)), 0);
  });

  testWidgets('the wave reaches the edges and leaves the hue: blue round '
      'every edge, the middle untouched, nothing scheduled', (tester) async {
    await _turnOn(tester);

    await tester.pump(_past(_waveOf(_phone)));

    _expectHue(await _picture(tester));
    _expectAtRest(tester);
  });

  testWidgets('turning off takes the hue away within 300 ms, and then it '
      'builds nothing again', (tester) async {
    await _pump(tester, running: true);
    await _pump(tester, running: false);
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 150));
    final fading = await _picture(tester);
    expect(fading.alpha(const Offset(195, 1)), inInclusiveRange(30, 100));

    await tester.pump(_past(const Duration(milliseconds: 150)));
    await tester.pump();

    expect(_paint, findsNothing);
    _expectAtRest(tester);
  });

  for (final (flag, disableAnimations) in [
    ('remove animations', true),
    ('reduce motion', false),
  ]) {
    testWidgets('with $flag there is no travelling wave: the hue fades in '
        'where it stays', (tester) async {
      if (!disableAnimations) {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(reduceMotion: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
      }
      await _turnOn(tester, disableAnimations: disableAnimations);

      await tester.pump(const Duration(milliseconds: 150));
      final arriving = await _picture(tester);
      // Round the button, where a wave would be at its strongest.
      final origin = meshButtonRect(_phone, EdgeInsets.zero).center;
      for (final step in [60.0, 120.0, 200.0]) {
        expect(arriving.alpha(origin + Offset(step, -step)), 0);
      }
      expect(arriving.alpha(const Offset(195, 1)), inInclusiveRange(30, 100));

      await tester.pump(_past(const Duration(milliseconds: 150)));

      _expectHue(await _picture(tester));
      _expectAtRest(tester);
    });
  }

  testWidgets('on any window the wave ends on its edges: phones, a fold '
      'closed and open, a tablet, and landscape beside a sensor housing', (
    tester,
  ) async {
    for (final (size, viewPadding) in [
      (const Size(320, 568), EdgeInsets.zero),
      (const Size(393, 852), const EdgeInsets.only(top: 59, bottom: 34)),
      (const Size(344, 882), EdgeInsets.zero),
      (const Size(768, 884), EdgeInsets.zero),
      (const Size(1032, 1376), EdgeInsets.zero),
      (const Size(852, 393), const EdgeInsets.only(left: 59, right: 59)),
    ]) {
      await _turnOn(tester, size: size, viewPadding: viewPadding);
      await tester.pump(_past(_waveOf(size, viewPadding)));

      _expectHue(await _picture(tester), reason: '$size');
      _expectAtRest(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a fold opened in the middle of the wave lands the hue on the '
      'new edges', (tester) async {
    const closed = Size(344, 882);
    const open = Size(768, 884);
    await _turnOn(tester, size: closed);
    await tester.pump(const Duration(milliseconds: 400));

    await _pump(tester, running: true, size: open);
    await tester.pump(_waveOf(closed));

    final picture = await _picture(tester);
    expect(picture.size, open);
    _expectHue(picture);
    // Where the closed window's right edge was is the middle of the map now.
    expect(picture.alpha(Offset(closed.width - 1, open.height / 2)), 0);
    _expectAtRest(tester);
  });

  testWidgets('ten rapid toggles settle on the last', (tester) async {
    for (final last in [true, false]) {
      await _pump(tester, running: !last);
      for (var i = 0; i < 10; i++) {
        await _pump(tester, running: i.isEven ? last : !last);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await _pump(tester, running: last);
      await tester.pumpAndSettle();

      if (last) {
        _expectHue(await _picture(tester));
      } else {
        expect(_paint, findsNothing);
      }
      _expectAtRest(tester);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a wave left in the background is settled at the first frame '
      'back', (tester) async {
    await _turnOn(tester);
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pump(const Duration(minutes: 30));

    _expectHue(await _picture(tester));
    _expectAtRest(tester);
  });

  testWidgets('a frame of the wave builds nothing, lays out nothing and '
      'repaints nothing under it', (tester) async {
    var builds = 0;
    var paints = 0;
    // A sibling in the shell's own layer, as the sheet and the banners are:
    // only the aura's own boundary keeps a frame of the wave off it.
    final under = Positioned.fill(
      child: Builder(
        builder: (context) {
          builds++;
          return CustomPaint(painter: _Counting(() => paints++));
        },
      ),
    );
    await _turnOn(tester, under: under);
    await tester.pump(const Duration(milliseconds: 100));
    final (builtBefore, paintedBefore) = (builds, paints);
    final widget = tester.widget(_paint);
    final before = await _picture(tester);
    final render = tester.renderObject(_paint);
    // The aura's own layer, and how often it alone has been painted.
    final layer = tester.renderObject<RenderRepaintBoundary>(
      find.ancestor(of: _paint, matching: find.byType(RepaintBoundary)).first,
    );
    final layerPaints = layer.debugAsymmetricPaintCount;

    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(render.debugNeedsLayout, isFalse);
    }

    // Each frame painted the wave again, in its own layer and no other.
    expect(layer.debugAsymmetricPaintCount, layerPaints + 10);

    final after = await _picture(tester);
    final probe =
        meshButtonRect(_phone, EdgeInsets.zero).center +
        const Offset(150, -150);
    expect(after.alpha(probe), isNot(before.alpha(probe)));
    expect(tester.widget(_paint), same(widget));
    expect((builds, paints), (builtBefore, paintedBefore));
  });

  testWidgets('it paints with no saveLayer', (tester) async {
    bool noSaveLayer(Symbol method, List<dynamic> arguments) {
      if (method == #saveLayer) throw StateError('a saveLayer');
      return true;
    }

    await _turnOn(tester);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_paint, paints..everything(noSaveLayer));

    await tester.pumpAndSettle();
    expect(_paint, paints..everything(noSaveLayer));
  });

  testWidgets('a tap and a drag reach what is under it in the middle of the '
      'wave, and under the settled hue', (tester) async {
    var taps = 0;
    var drags = 0;
    final under = Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps++,
        onPanUpdate: (_) => drags++,
      ),
    );
    await _turnOn(tester, under: under);
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tapAt(const Offset(2, 400));
    await tester.dragFrom(const Offset(195, 400), const Offset(60, 0));
    expect(taps, 1);
    expect(drags, greaterThan(0));

    await tester.pumpAndSettle();
    drags = 0;
    await tester.tapAt(const Offset(2, 2));
    await tester.dragFrom(const Offset(388, 400), const Offset(-60, 0));
    expect(taps, 2);
    expect(drags, greaterThan(0));
  });

  testWidgets('it adds nothing to the semantics tree', (tester) async {
    final handle = tester.ensureSemantics();
    final under = Positioned.fill(
      child: Semantics(label: 'map', child: const SizedBox.expand()),
    );
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

    await _pump(tester, running: false, under: under);
    final without = nodes();
    expect(find.bySemanticsLabel('map'), findsOneWidget);

    await _pump(tester, running: true, under: under);
    await tester.pump(const Duration(milliseconds: 300));
    expect(nodes(), without);
    await tester.pumpAndSettle();
    expect(nodes(), without);
    handle.dispose();
  });

  group('over the shell', () {
    Future<({FakeMeshService mesh, FakeMeshRadio radio})> pumpAura(
      WidgetTester tester, {
      required bool on,
    }) async {
      _window(tester, _phone);
      final mesh = FakeMeshService()
        ..statsAnswer = meshState(on: on, onForMs: 3600000);
      final radio = FakeMeshRadio()
        ..statusAnswer = radioStatus(
          on ? MeshRadioState.running : MeshRadioState.stopped,
          wanted: on,
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            meshServiceProvider.overrideWithValue(mesh),
            meshRadioProvider.overrideWithValue(radio),
          ],
          child: const MediaQuery(
            data: MediaQueryData(size: _phone),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: MeshAura(),
            ),
          ),
        ),
      );
      return (mesh: mesh, radio: radio);
    }

    testWidgets('mesh already running when the map opens is the hue, never '
        'a wave', (tester) async {
      await pumpAura(tester, on: true);
      // Before the radio and the engine have answered there is nothing.
      expect(find.byType(MeshAuraOverlay), findsNothing);

      await tester.pump();
      await tester.pump();

      _expectHue(await _picture(tester));
      _expectAtRest(tester);
    });

    testWidgets('the wave starts when the radio says it runs, and the hue '
        'goes when it says it stopped', (tester) async {
      final t = await pumpAura(tester, on: false);
      await tester.pump();
      await tester.pump();
      expect(_paint, findsNothing);

      t.mesh.statsAnswer = meshState(on: true, onForMs: 3600000);
      t.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // In the middle of its wave: the far edge has no hue yet.
      final wave = await _picture(tester);
      expect(wave.alpha(Offset(_phone.width - 1, 1)), 0);
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      await tester.pumpAndSettle();
      _expectHue(await _picture(tester));

      t.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pump();
      await tester.pump(_past(kMeshHueFade));
      await tester.pump();

      expect(_paint, findsNothing);
      _expectAtRest(tester);
    });

    testWidgets('Bluetooth switched off takes the hue away: a paused mesh '
        'is not one that runs', (tester) async {
      final t = await pumpAura(tester, on: true);
      await tester.pump();
      await tester.pump();

      t.radio.emit(radioStatus(MeshRadioState.paused, wanted: true));
      await tester.pump();
      await tester.pump(_past(kMeshHueFade));
      await tester.pump();

      expect(_paint, findsNothing);
    });
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
