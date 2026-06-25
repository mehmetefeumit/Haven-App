/// Shared helper to recenter the map on a point with consistent feedback.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/map_controller_provider.dart';
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
  final currentZoom = controller.camera.zoom;
  final zoom = currentZoom < minZoom ? minZoom : currentZoom;
  controller.move(target, zoom);

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
