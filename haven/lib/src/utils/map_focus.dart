/// Shared helper to recenter the map on a point with consistent feedback.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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
