/// Map layer drawing edge "droplet" indicators for off-screen circle members.
///
/// A screen-space overlay placed inside `FlutterMap.children`: reading
/// `MapCamera.of(context)` makes it rebuild on every pan/zoom frame, so each
/// droplet's position, size, and morph track the user's drag exactly. Members
/// that are on-screen are rendered as full markers by [MemberMarkersLayer]
/// instead; the two layers partition the list with the same geometry.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/edge_indicator_geometry.dart';
import 'package:haven/src/widgets/map/edge_member_indicator.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';
import 'package:latlong2/latlong.dart';

/// One off-screen member paired with its projection against the viewport.
class _DropletEntry {
  _DropletEntry({required this.member, required this.projection});

  final MemberLocation member;
  final EdgeProjection projection;
}

/// Draws the off-screen subset of [members] as edge droplets.
class OffScreenMemberIndicatorsLayer extends StatelessWidget {
  /// Creates an [OffScreenMemberIndicatorsLayer].
  const OffScreenMemberIndicatorsLayer({
    required this.members,
    required this.bottomInset,
    required this.onFocusMember,
    super.key,
  });

  /// All circle members with a known location (on- and off-screen).
  final List<MemberLocation> members;

  /// Logical pixels at the bottom of the viewport occluded by the collapsed
  /// bottom sheet, kept consistent with [MemberMarkersLayer].
  final double bottomInset;

  /// Called when a droplet is tapped — recenters the map on the member.
  final void Function(MemberLocation member) onFocusMember;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final topInset = MediaQuery.maybeOf(context)?.viewPadding.top ?? 0;
    final viewport = edgeViewport(
      viewport: camera.nonRotatedSize,
      topInset: topInset,
      bottomInset: bottomInset,
    );

    final entries = <_DropletEntry>[];
    for (final member in members) {
      final geoPoint = camera.latLngToScreenOffset(
        LatLng(member.latitude, member.longitude),
      );
      final avatarCenter = geoPoint - const Offset(0, kAvatarCenterLift);
      final projection = projectMemberToEdge(
        avatarCenter: avatarCenter,
        viewport: viewport,
      );
      if (!projection.offScreen) continue;
      entries.add(_DropletEntry(member: member, projection: projection));
    }

    if (entries.isEmpty) return const SizedBox.shrink();

    // Nudge overlapping droplets apart along their shared edge so each stays
    // legible (v1: spread + stack, accept minor overlap when an edge is full).
    final heads = _spread(entries, viewport.safeRect);

    // Draw nearer (larger) droplets last so they sit on top of farther ones.
    entries.sort(
      (a, b) => a.projection.diameter.compareTo(b.projection.diameter),
    );

    final droplets = <Widget>[
      for (final entry in entries)
        _positioned(
          entry,
          heads[entry.member.pubkey] ?? entry.projection.headCenter,
          colorScheme,
          viewport.safeRect,
        ),
    ];

    // Clip to the viewport so each droplet's outward nub merges into the
    // screen border rather than floating free.
    return ClipRect(
      child: Stack(
        key: WidgetKeys.offScreenIndicatorsLayer,
        clipBehavior: Clip.none,
        children: droplets,
      ),
    );
  }

  Widget _positioned(
    _DropletEntry entry,
    Offset head,
    ColorScheme scheme,
    Rect safeRect,
  ) {
    final projection = entry.projection;
    final member = entry.member;
    final footprint = EdgeMemberIndicator.footprintFor(projection.diameter);
    // Bias the tap target inward near a screen edge so the full 48dp hit-box
    // stays on-screen while the visible droplet remains welded to the border.
    final tapOffset =
        tapTargetCenter(
          head: head,
          diameter: projection.diameter,
          safeRect: safeRect,
        ) -
        head;
    return Positioned(
      key: ValueKey<String>('edge_pos_${member.pubkey}'),
      left: head.dx - footprint / 2,
      top: head.dy - footprint / 2,
      width: footprint,
      height: footprint,
      child: EdgeMemberIndicator(
        key: WidgetKeys.edgeIndicator(member.pubkey),
        initials: markerInitials(member.displayName, member.pubkey),
        publicKey: member.pubkey,
        fillColor: avatarHue(member.pubkey, scheme),
        haloColor: scheme.surface,
        diameter: projection.diameter,
        morph: projection.morph,
        angle: projection.angle,
        semanticsLabel: offScreenSemanticsLabel(
          member.displayName,
          projection.angle,
        ),
        onTap: () => onFocusMember(member),
        tapOffset: tapOffset,
      ),
    );
  }

  /// Returns adjusted head centres keyed by pubkey, separating droplets that
  /// land on the same edge so they do not stack directly on top of each other.
  Map<String, Offset> _spread(List<_DropletEntry> entries, Rect safe) {
    final result = <String, Offset>{
      for (final e in entries) e.member.pubkey: e.projection.headCenter,
    };

    // Bucket each droplet by the safe-rect edge it is clamped to.
    // 0 = top, 1 = bottom, 2 = left, 3 = right.
    final byEdge = <int, List<_DropletEntry>>{};
    for (final e in entries) {
      final h = e.projection.headCenter;
      final distances = <double>[
        (h.dy - safe.top).abs(),
        (safe.bottom - h.dy).abs(),
        (h.dx - safe.left).abs(),
        (safe.right - h.dx).abs(),
      ];
      var edge = 0;
      var best = distances[0];
      for (var i = 1; i < distances.length; i++) {
        if (distances[i] < best) {
          best = distances[i];
          edge = i;
        }
      }
      byEdge.putIfAbsent(edge, () => <_DropletEntry>[]).add(e);
    }

    for (final group in byEdge.entries) {
      final horizontal = group.key == 0 || group.key == 1;
      final list = group.value
        ..sort((a, b) {
          final pa = horizontal
              ? a.projection.headCenter.dx
              : a.projection.headCenter.dy;
          final pb = horizontal
              ? b.projection.headCenter.dx
              : b.projection.headCenter.dy;
          final cmp = pa.compareTo(pb);
          return cmp != 0 ? cmp : a.member.pubkey.compareTo(b.member.pubkey);
        });

      final lo = horizontal ? safe.left : safe.top;
      final hi = horizontal ? safe.right : safe.bottom;
      double? prevPos;
      double? prevTapHalf;
      for (final e in list) {
        final h = e.projection.headCenter;
        final radius = e.projection.diameter / 2;
        // Separate by the 48dp tap-target size, not the (smaller) visual
        // radius, so adjacent droplets' hit-boxes do not overlap and taps stay
        // unambiguous on a crowded edge.
        final tapHalf = math.max(e.projection.diameter, kMinTapTarget) / 2;
        var pos = horizontal ? h.dx : h.dy;
        if (prevPos != null && prevTapHalf != null) {
          final minGap = prevTapHalf + tapHalf;
          if (pos - prevPos < minGap) pos = prevPos + minGap;
        }
        // Keep the visible droplet on the segment when it is wide enough.
        if (hi - radius > lo + radius) {
          pos = pos.clamp(lo + radius, hi - radius);
        }
        prevPos = pos;
        prevTapHalf = tapHalf;
        result[e.member.pubkey] = horizontal
            ? Offset(pos, h.dy)
            : Offset(h.dx, pos);
      }
    }
    return result;
  }
}
