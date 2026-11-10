/// Interpolation for a member marker gliding from one fix to the next.
library;

import 'package:latlong2/latlong.dart';

/// The point [t] of the way from [from] to [to].
///
/// Longitude takes the short way round the antimeridian: a plain lerp from
/// 179 to -179 would sweep the marker across the whole map.
LatLng glideLerp(LatLng from, LatLng to, double t) {
  if (t <= 0) return from;
  if (t >= 1) return to;
  final dLng = ((to.longitude - from.longitude + 540) % 360) - 180;
  final lng = ((from.longitude + dLng * t + 540) % 360) - 180;
  return LatLng(from.latitude + (to.latitude - from.latitude) * t, lng);
}
