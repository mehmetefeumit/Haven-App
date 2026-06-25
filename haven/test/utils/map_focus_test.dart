/// Tests for the shared map-focus camera helpers in `utils/map_focus.dart`.
///
/// Focuses on [resetMapToHome] — the camera reset behind the recenter button —
/// verifying that it returns to the user's location, restores the default
/// zoom, and clears any manual rotation back to north-up (0°) in a single
/// camera update.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/map_focus.dart';
import 'package:latlong2/latlong.dart';

void main() {
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
    fakeCamera = fakeCamera.withPosition(center: center, zoom: zoom);
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
