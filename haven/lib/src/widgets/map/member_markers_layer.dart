/// Map layer rendering [MemberMarker]s for on-screen circle members.
///
/// Off-screen members are intentionally omitted here — the
/// [OffScreenMemberIndicatorsLayer] draws their edge droplets instead — so the
/// same member is never rendered twice. Both layers partition the member list
/// with the same pure [projectMemberToEdge] geometry against the live map
/// camera, so their on/off-screen decisions always agree.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/edge_indicator_geometry.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';
import 'package:haven/src/widgets/map/member_marker.dart';
import 'package:latlong2/latlong.dart';

/// Renders the on-screen subset of [members] as [MemberMarker]s.
class MemberMarkersLayer extends StatelessWidget {
  /// Creates a [MemberMarkersLayer].
  const MemberMarkersLayer({
    required this.members,
    required this.bottomInset,
    this.onMarkerTap,
    super.key,
  });

  /// All circle members with a known location (on- and off-screen).
  final List<MemberLocation> members;

  /// Logical pixels at the bottom of the viewport occluded by the collapsed
  /// bottom sheet, kept consistent with the off-screen indicator layer.
  final double bottomInset;

  /// Optional per-marker tap handler (iOS "Open in Apple Maps").
  final void Function(MemberLocation member)? onMarkerTap;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final topInset = MediaQuery.maybeOf(context)?.viewPadding.top ?? 0;
    final viewport = edgeViewport(
      viewport: camera.nonRotatedSize,
      topInset: topInset,
      bottomInset: bottomInset,
    );

    final markers = <Marker>[];
    for (final member in members) {
      final geoPoint = camera.latLngToScreenOffset(
        LatLng(member.latitude, member.longitude),
      );
      final avatarCenter = geoPoint - const Offset(0, kAvatarCenterLift);
      final projection = projectMemberToEdge(
        avatarCenter: avatarCenter,
        viewport: viewport,
      );
      if (projection.offScreen) continue;
      markers.add(_marker(member));
    }
    return MarkerLayer(markers: markers);
  }

  Marker _marker(MemberLocation member) {
    final tap = onMarkerTap;
    return Marker(
      point: LatLng(member.latitude, member.longitude),
      // Footprint matches the legacy inline marker: width covers the pulse at
      // its max scale, height adds the tail's visible drop.
      width: 80,
      height: 96,
      alignment: Alignment.topCenter,
      child: MemberMarker(
        key: WidgetKeys.memberMarker(member.pubkey),
        initials: markerInitials(member.displayName, member.pubkey),
        publicKey: member.pubkey,
        lastSeen: member.timestamp,
        onTap: tap == null ? null : () => tap(member),
      ),
    );
  }
}
