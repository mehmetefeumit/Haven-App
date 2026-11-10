/// Tests for the shared map-focus camera helpers in `utils/map_focus.dart`.
///
/// Focuses on [resetMapToHome] — the camera reset behind the recenter button —
/// verifying that it returns to the user's location, restores the default
/// zoom, and clears any manual rotation back to north-up (0°) in a single
/// camera update.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/utils/map_focus.dart';
import 'package:latlong2/latlong.dart';

void main() {
  tearDown(cancelMapFocusGlide);

  group('focusMapOnPoint', () {
    const near = LatLng(0.002, 0.002);

    late _FakeMapController controller;
    late WidgetRef ref;
    late BuildContext context;

    Future<void> host(
      WidgetTester tester, {
      MapCamera? camera,
      bool disableAnimations = false,
    }) async {
      controller = _FakeMapController();
      if (camera != null) controller.fakeCamera = camera;
      addTearDown(() => unawaited(controller.events.close()));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mapControllerProvider.overrideWithValue(controller)],
          child: MediaQuery(
            data: MediaQueryData(disableAnimations: disableAnimations),
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Consumer(
                builder: (c, r, _) {
                  ref = r;
                  context = c;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
    }

    void focus(LatLng target, {double minZoom = 14}) => focusMapOnPoint(
      ref: ref,
      context: context,
      target: target,
      announcementName: 'x',
      minZoom: minZoom,
    );

    testWidgets('glides: nothing until the first frame, midway at 200 ms, '
        'exactly the target at 400 ms', (tester) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      expect(controller.moveCalls, isEmpty);

      await tester.pump();
      expect(controller.fakeCamera.center, const LatLng(0, 0));
      expect(controller.fakeCamera.zoom, 13.5);

      await tester.pump(const Duration(milliseconds: 200));
      final mid = controller.moveCalls.last;
      expect(mid.center.latitude, inExclusiveRange(0, near.latitude));
      expect(mid.center.longitude, inExclusiveRange(0, near.longitude));
      expect(mid.zoom, inExclusiveRange(13.5, 14));

      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.moveCalls.last, (center: near, zoom: 14.0));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('never zooms out below minZoom and ends exactly on it', (
      tester,
    ) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.moveCalls.last.zoom, 14.0);
      expect(controller.moveCalls.every((m) => m.zoom >= 13.5), isTrue);
    });

    testWidgets('keeps a higher current zoom', (tester) async {
      await host(tester, camera: _camera(zoom: 16));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.moveCalls.every((m) => m.zoom == 16), isTrue);
      expect(controller.moveCalls.last.center, near);
    });

    testWidgets('a zoom change over one level cuts', (tester) async {
      await host(tester, camera: _camera(zoom: 5));
      focus(const LatLng(1, 1));
      expect(controller.moveCalls, [(center: const LatLng(1, 1), zoom: 14.0)]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a target over two viewports away cuts', (tester) async {
      await host(tester);
      focus(const LatLng(0.1, 0.1));
      expect(controller.moveCalls, [
        (center: const LatLng(0.1, 0.1), zoom: 15.0),
      ]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduce motion (MediaQuery) cuts', (tester) async {
      await host(tester, camera: _camera(zoom: 13.5), disableAnimations: true);
      focus(near);
      expect(controller.moveCalls, [(center: near, zoom: 14.0)]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('reduce motion (engine flag) cuts', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(reduceMotion: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      expect(controller.moveCalls, [(center: near, zoom: 14.0)]);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('the glide never cancels itself with its own move events', (
      tester,
    ) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.moveCalls.last.center, near);
    });

    testWidgets('a user gesture mid-glide stops it', (tester) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final seen = controller.moveCalls.length;

      controller.events.add(
        MapEventMoveStart(
          source: MapEventSource.dragStart,
          camera: controller.fakeCamera,
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.moveCalls, hasLength(seen));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('another camera command mid-glide stops it', (tester) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final seen = controller.moveCalls.length;

      // A zoom button's `move` carries the `mapController` source the glide
      // ignores, so only the camera's pose gives it away.
      controller.fakeCamera = controller.fakeCamera.withPosition(
        center: const LatLng(0.001, -0.001),
        zoom: 15,
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.moveCalls, hasLength(seen));
      expect(controller.fakeCamera.zoom, 15);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a disposed map stops it without a move or an exception', (
      tester,
    ) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final seen = controller.moveCalls.length;

      unawaited(controller.events.close());
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.moveCalls, hasLength(seen));
      expect(tester.takeException(), isNull);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a second focus mid-glide replaces the first', (tester) async {
      const second = LatLng(-0.002, 0.001);
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      focus(second);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(controller.moveCalls.any((m) => m.center == near), isFalse);
      expect(controller.moveCalls.last, (center: second, zoom: 14.0));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('a cut cancels a glide in flight', (tester) async {
      await host(tester, camera: _camera(zoom: 13.5));
      focus(near);
      await tester.pump();
      focus(const LatLng(1, 1));
      final seen = controller.moveCalls.length;
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.moveCalls, hasLength(seen));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('resetMapToHome', () {
    const target = LatLng(48.2082, 16.3738); // Vienna
    const defaultZoom = 15.0;

    test('recenters on the target at the default zoom with north-up '
        'rotation', () {
      final controller = _FakeMapController();

      resetMapToHome(
        controller: controller,
        target: target,
        defaultZoom: defaultZoom,
      );

      expect(controller.moveAndRotateCalls, hasLength(1));
      final call = controller.moveAndRotateCalls.single;
      expect(call.center, target);
      expect(call.zoom, defaultZoom);
      // 0° is north-up; the button must undo any manual rotation.
      expect(call.degree, 0.0);
    });

    test('resets rotation to 0 even when the camera is currently rotated', () {
      final controller = _FakeMapController()
        ..fakeCamera = _camera(rotation: 137);

      resetMapToHome(
        controller: controller,
        target: target,
        defaultZoom: defaultZoom,
      );

      expect(controller.moveAndRotateCalls.single.degree, 0.0);
    });

    test('restores the default zoom even when the camera is zoomed out', () {
      final controller = _FakeMapController()..fakeCamera = _camera(zoom: 4);

      resetMapToHome(
        controller: controller,
        target: target,
        defaultZoom: defaultZoom,
      );

      expect(controller.moveAndRotateCalls.single.zoom, defaultZoom);
    });

    test('uses the supplied default zoom rather than a hard-coded value', () {
      final controller = _FakeMapController();

      resetMapToHome(
        controller: controller,
        target: target,
        defaultZoom: 12.5,
      );

      expect(controller.moveAndRotateCalls.single.zoom, 12.5);
    });

    test('issues exactly one camera update, not a separate move + rotate', () {
      final controller = _FakeMapController();

      resetMapToHome(
        controller: controller,
        target: target,
        defaultZoom: defaultZoom,
      );

      // `move` is never called separately — a single `moveAndRotate` avoids an
      // intermediate frame at a half-applied camera.
      expect(controller.moveCalls, isEmpty);
      expect(controller.moveAndRotateCalls, hasLength(1));
    });
  });
}

MapCamera _camera({double zoom = 15, double rotation = 0}) => MapCamera(
  crs: const Epsg3857(),
  center: const LatLng(0, 0),
  zoom: zoom,
  rotation: rotation,
  nonRotatedSize: const Size(400, 800),
);

/// Minimal test fake for flutter_map's [MapController].
///
/// Records [moveAndRotate] and [move] calls so the helper's exact camera
/// update can be asserted; everything else inherits `Fake`'s `noSuchMethod`
/// so an accidental new call in production code surfaces as a test failure
/// rather than silently succeeding.
class _FakeMapController extends Fake implements MapController {
  final List<({LatLng center, double zoom})> moveCalls = [];
  final List<({LatLng center, double zoom, double degree})> moveAndRotateCalls =
      [];

  MapCamera fakeCamera = _camera();

  /// Stands in for the real controller's event stream; `move` echoes a
  /// `mapController`-sourced event as the real one does.
  final StreamController<MapEvent> events = StreamController.broadcast(
    sync: true,
  );

  @override
  Stream<MapEvent> get mapEventStream => events.stream;

  @override
  MapCamera get camera => fakeCamera;

  @override
  bool move(
    LatLng center,
    double zoom, {
    Offset offset = Offset.zero,
    String? id,
  }) {
    moveCalls.add((center: center, zoom: zoom));
    final old = fakeCamera;
    fakeCamera = old.withPosition(center: center, zoom: zoom);
    if (!events.isClosed) {
      events.add(
        MapEventMove(
          source: MapEventSource.mapController,
          oldCamera: old,
          camera: fakeCamera,
        ),
      );
    }
    return true;
  }

  // `MoveAndRotateResult` is not exported from flutter_map's public surface,
  // so the structurally-identical record type is spelled out here.
  @override
  ({bool moveSuccess, bool rotateSuccess}) moveAndRotate(
    LatLng center,
    double zoom,
    double degree, {
    String? id,
  }) {
    moveAndRotateCalls.add((center: center, zoom: zoom, degree: degree));
    fakeCamera = fakeCamera.withPosition(center: center, zoom: zoom);
    return (moveSuccess: true, rotateSuccess: true);
  }
}
