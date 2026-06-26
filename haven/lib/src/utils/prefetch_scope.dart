/// Pure functions extracted from `_MapPageState._triggerPrefetch` for
/// unit-testability.
///
/// These helpers contain no Flutter or Riverpod dependencies and can be
/// exercised in plain Dart unit tests without a widget harness or Rust bridge.
library;

import 'package:haven/src/services/location_sharing_service.dart'
    show MemberLocation;
import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// nearestMemberPoints
// ---------------------------------------------------------------------------

/// Returns member coordinates sorted by squared-degree distance from
/// [cameraCenter] (nearest first).
///
/// Uses degree deltas for the distance metric — sufficient for nearest-member
/// ordering over the small geographic areas Haven typically covers, and avoids
/// a `sqrt` call.
///
/// The returned list is a freshly allocated copy; the original [members] list
/// is not mutated.
List<LatLng> nearestMemberPoints(
  List<MemberLocation> members,
  LatLng cameraCenter,
) {
  final sorted = List<MemberLocation>.from(members)
    ..sort((a, b) {
      final da = _squaredDegreeDistance(
        cameraCenter,
        LatLng(a.latitude, a.longitude),
      );
      final db = _squaredDegreeDistance(
        cameraCenter,
        LatLng(b.latitude, b.longitude),
      );
      return da.compareTo(db);
    });
  return sorted.map((m) => LatLng(m.latitude, m.longitude)).toList();
}

// ---------------------------------------------------------------------------
// prefetchLandingZoom
// ---------------------------------------------------------------------------

/// Returns the tile zoom level to prefetch for a member landing view.
///
/// Mirrors `focusMapOnPoint`'s zoom floor of 14 and clamps the result to the
/// map's valid range `[3, maxNativeZoom]`.
///
/// - [currentZoom] — the camera's current zoom level.
/// - [maxNativeZoom] — the tile provider's maximum native zoom.
int prefetchLandingZoom(double currentZoom, int maxNativeZoom) {
  const minLandingZoom = 14.0;
  final landing =
      currentZoom < minLandingZoom ? minLandingZoom : currentZoom;
  return landing.clamp(3.0, maxNativeZoom.toDouble()).round();
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Squared degree-delta distance between [a] and [b].
///
/// Order-preserving (no `sqrt` needed) and sufficient for nearby-member
/// sorting. Named to reflect what it actually computes: `dLat² + dLng²`.
double _squaredDegreeDistance(LatLng a, LatLng b) {
  final dLat = a.latitude - b.latitude;
  final dLng = a.longitude - b.longitude;
  return dLat * dLat + dLng * dLng;
}
