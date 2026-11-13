/// Shared helper to recenter the map on a point with consistent feedback.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
import 'package:haven/src/utils/marker_glide.dart';
import 'package:haven/src/utils/reduce_motion.dart';
import 'package:latlong2/latlong.dart';

/// Recenters the shared map camera on [target], never zooming out below
/// [minZoom], and confirms the action with light haptic feedback and a
/// screen-reader announcement.
///
/// Shared by the members list (tapping a member tile) and the off-screen edge
/// droplets (tapping a droplet) so both jump-to-member affordances behave
/// identically. [announcementName] is the already-resolved display name spoken
/// to assistive technology.
void focusMapOnPoint({
  required WidgetRef ref,
  required BuildContext context,
  required LatLng target,
  required String announcementName,
  double minZoom = 14,
}) {
  final controller = ref.read(mapControllerProvider);
  final camera = controller.camera;
  final fromCenter = camera.center;
  final fromZoom = camera.zoom;
  final toZoom = math.max(fromZoom, minZoom);

  // A far jump is cut: lerping centre and zoom from far away swoops the target
  // off-screen mid-flight and bills a tile strip from the tile provider at
  // every intermediate zoom.
  final distance =
      (camera.latLngToScreenOffset(target) -
              camera.latLngToScreenOffset(fromCenter))
          .distance;
  final canGlide =
      (toZoom - fromZoom).abs() <= 1 &&
      distance <= 2 * camera.nonRotatedSize.longestSide &&
      !reduceMotionOf(context);
  if (canGlide) {
    _glide.start(controller, target, toZoom);
  } else {
    _glide.cancel();
    controller.move(target, toZoom);
  }

  // `lightImpact` maps to `UIImpactFeedbackGenerator(.light)` on iOS and
  // conveys "action completed" rather than "value changing".
  unawaited(HapticFeedback.lightImpact());
  unawaited(
    SemanticsService.sendAnnouncement(
      View.of(context),
      "Map centered on $announcementName's location",
      Directionality.of(context),
    ),
  );
}

/// Stops any recentre glide in flight; the glide is process-global state.
@visibleForTesting
void cancelMapFocusGlide() => _glide.cancel();

final _MapFocusGlide _glide = _MapFocusGlide();

/// Map motion already in flight when the user taps. The tap is the newer
/// intent, so the glide supersedes it instead of yielding to it.
const Set<MapEventSource> _momentum = {
  MapEventSource.flingAnimationController,
  MapEventSource.doubleTapZoomAnimationController,
};

/// The one recentre tween. Any gesture on the map, a newer focus, or the map's
/// disposal ends it, so it never fights the user or moves a disposed map.
class _MapFocusGlide {
  static const Duration _duration = Duration(milliseconds: 400);

  Ticker? _ticker;
  StreamSubscription<MapEvent>? _events;

  void start(MapController controller, LatLng target, double toZoom) {
    cancel();
    late LatLng fromCenter;
    late double fromZoom;
    late LatLng lastCenter;
    late double lastZoom;
    var owned = false;
    final ticker = Ticker((elapsed) {
      final camera = controller.camera;
      if (!owned) {
        // Momentum keeps moving the camera until a `move` of ours changes it
        // (flutter_map then stops it), so start from wherever it has got to.
        fromCenter = camera.center;
        fromZoom = camera.zoom;
      } else if (camera.center != lastCenter || camera.zoom != lastZoom) {
        // A zoom or home button moves the camera with the same source the
        // glide emits itself, so a pose it did not set is the only sign of it.
        cancel();
        return;
      }
      final t = elapsed.inMicroseconds / _duration.inMicroseconds;
      if (t >= 1) {
        cancel();
        controller.move(target, toZoom);
        return;
      }
      final c = Curves.easeInOutCubic.transform(t);
      lastCenter = glideLerp(fromCenter, target, c);
      lastZoom = lerpDouble(fromZoom, toZoom, c)!;
      if (controller.move(lastCenter, lastZoom)) owned = true;
    });
    _ticker = ticker;
    // `move` emits a `mapController` event, so the tween never cancels itself.
    _events = controller.mapEventStream.listen(
      (event) {
        // A double-tap zoom that starts now is newer input than the tap; a
        // fling cannot start without a drag, which already cancels.
        if (event is MapEventDoubleTapZoomStart ||
            (event.source != MapEventSource.mapController &&
                !_momentum.contains(event.source))) {
          cancel();
        }
      },
      onDone: cancel,
    );
    unawaited(ticker.start());
  }

  void cancel() {
    unawaited(_events?.cancel());
    _events = null;
    final ticker = _ticker;
    _ticker = null;
    ticker?.dispose();
  }
}

/// Resets the shared map camera to Haven's default "home" view: centered on
/// [target] at [defaultZoom] with the rotation cleared to north-up (0°).
///
/// Used by the recenter button so a single tap not only returns to the user's
/// location but also undoes any manual pinch-zoom or two-finger rotation,
/// restoring the exact camera the app first opens with on launch. [defaultZoom]
/// is threaded in (rather than hard-coded here) so it stays in lockstep with
/// the map's `initialZoom`.
void resetMapToHome({
  required MapController controller,
  required LatLng target,
  required double defaultZoom,
}) {
  // `moveAndRotate` performs the recenter, zoom reset, and rotation reset in a
  // single camera update — more efficient than separate `move` + `rotate`
  // calls, and avoids an intermediate frame at a half-applied camera.
  controller.moveAndRotate(target, defaultZoom, 0);
}
