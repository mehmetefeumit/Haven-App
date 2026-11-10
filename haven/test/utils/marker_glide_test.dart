/// Tests for [glideLerp], the interpolation behind a marker's glide.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/utils/marker_glide.dart';
import 'package:latlong2/latlong.dart';

void main() {
  const a = LatLng(10, 10);
  const b = LatLng(30, 20);

  test('t = 0 and t = 1 return the endpoints exactly', () {
    expect(glideLerp(a, b, 0), a);
    expect(glideLerp(a, b, 1), b);
  });

  test('a plain span interpolates linearly', () {
    final mid = glideLerp(a, b, 0.5);
    expect(mid.latitude, closeTo(20, 1e-12));
    expect(mid.longitude, closeTo(15, 1e-12));
  });

  test('179 to -179 goes the short way through the antimeridian', () {
    const from = LatLng(0, 179);
    const to = LatLng(0, -179);
    expect(glideLerp(from, to, 0.5).longitude.abs(), closeTo(180, 1e-9));
    // A quarter of the way is still on the eastern side of 180.
    expect(glideLerp(from, to, 0.25).longitude, closeTo(179.5, 1e-9));
    expect(glideLerp(from, to, 0.75).longitude, closeTo(-179.5, 1e-9));
  });

  test('-179 to 179 goes the short way through the antimeridian', () {
    const from = LatLng(0, -179);
    const to = LatLng(0, 179);
    expect(glideLerp(from, to, 0.5).longitude.abs(), closeTo(180, 1e-9));
    expect(glideLerp(from, to, 0.25).longitude, closeTo(-179.5, 1e-9));
    expect(glideLerp(from, to, 0.75).longitude, closeTo(179.5, 1e-9));
  });

  test('the result always lies within [-180, 180]', () {
    const from = LatLng(0, 170);
    const to = LatLng(0, -170);
    for (var i = 0; i <= 20; i++) {
      final lng = glideLerp(from, to, i / 20).longitude;
      expect(lng, inInclusiveRange(-180, 180));
    }
  });
}
