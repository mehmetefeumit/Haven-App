/// The one great-circle distance in the app.
///
/// Shared rather than duplicated because two copies would be two independent
/// definitions of `kMotionTriggerDistanceMeters`. The motion trigger that
/// decides to PUBLISH (`map_shell.dart`) and the iOS profile controller that
/// decides to leave the coarse accuracy tier (`ios_location_source.dart`) both
/// measure "did the device move 100 m?", and they must answer identically: a
/// displacement that flips the accuracy profile but never fires a publish
/// spends the GPS receiver for nothing, and the reverse publishes a coordinate
/// the session never returned to Best to take.
library;

import 'dart:math' as math;

/// Earth mean radius in metres — the sphere the haversine approximates.
const double _earthRadiusMeters = 6371000;

/// Great-circle distance in metres between two WGS-84 points.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  final dLat = _toRadians(lat2 - lat1);
  final dLon = _toRadians(lon2 - lon1);
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_toRadians(lat1)) *
          math.cos(_toRadians(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _toRadians(double degrees) => degrees * math.pi / 180;
