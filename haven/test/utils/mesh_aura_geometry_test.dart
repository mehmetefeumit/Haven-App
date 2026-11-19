// The mesh aura's geometry (`docs/BLUETOOTH_MESH_AURA_DESIGN.md` §2): pure
// functions of the window's size, so the wave reaches the edge of any screen
// and the button is where the wave starts.
import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/map_layout.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';

/// The windows the design tabulates: a small phone, two current ones, a fold
/// closed and open, a tablet.
const _windows = [
  Size(375, 667),
  Size(393, 852),
  Size(440, 956),
  Size(344, 882),
  Size(768, 884),
  Size(1032, 1376),
];

void main() {
  test('the button is a 48 dp square in the bottom-left corner, level with '
      'the map controls above the collapsed sheet', () {
    for (final window in _windows) {
      final rect = meshButtonRect(window, EdgeInsets.zero);

      expect(rect.size, const Size(48, 48), reason: '$window');
      expect(rect.left, 16, reason: '$window');
      // The map controls sit 16 above the collapsed sheet.
      expect(
        window.height - rect.bottom,
        closeTo(window.height * kCollapsedSheetFraction + 16, 1e-9),
        reason: '$window',
      );
    }
  });

  test('the button is held clear of a sensor housing on the left, and is '
      'moved by no other inset', () {
    const window = Size(852, 393);
    final plain = meshButtonRect(window, EdgeInsets.zero);

    expect(
      meshButtonRect(window, const EdgeInsets.only(left: 59)),
      plain.shift(const Offset(59, 0)),
    );
    expect(
      meshButtonRect(
        window,
        const EdgeInsets.only(top: 47, right: 59, bottom: 34),
      ),
      plain,
    );
  });

  test('the wave reaches every corner of any window', () {
    final random = Random(20261112);
    for (var i = 0; i < 1000; i++) {
      final window = Size(
        200 + random.nextDouble() * 2000,
        200 + random.nextDouble() * 2000,
      );
      final origin = meshButtonRect(
        window,
        EdgeInsets.only(left: random.nextDouble() * 60),
      ).center;
      final reach = waveReach(window, origin);

      for (final corner in [
        Offset.zero,
        Offset(window.width, 0),
        Offset(0, window.height),
        Offset(window.width, window.height),
      ]) {
        expect(
          reach,
          greaterThanOrEqualTo((corner - origin).distance),
          reason: '$window',
        );
      }
      // And no further than the farthest of them.
      expect(
        reach,
        lessThanOrEqualTo(window.bottomRight(Offset.zero).distance),
      );
    }
  });

  test('the wave takes longer on a larger window, never under 0.9 s nor over '
      '1.4 s', () {
    var last = Duration.zero;
    for (var reach = 0.0; reach <= 4000; reach += 25) {
      final duration = waveDuration(reach);

      expect(duration, greaterThanOrEqualTo(last), reason: '$reach');
      expect(duration.inMilliseconds, inInclusiveRange(900, 1400));
      last = duration;
    }
    expect(waveDuration(0).inMilliseconds, 900);
    expect(waveDuration(4000).inMilliseconds, 1400);
  });

  test('on the windows the design tabulates the reach, the duration and the '
      "hue's width are the design's", () {
    const tabulated = [
      (641, 921, 22.5),
      (793, 996, 23.6),
      (896, 1048, 26.4),
      (796, 998, 20.6),
      (1037, 1118, 32.0),
      (1535, 1367, 32.0),
    ];
    for (final (i, window) in _windows.indexed) {
      final (reach, millis, hue) = tabulated[i];
      final origin = meshButtonRect(window, EdgeInsets.zero).center;
      final measured = waveReach(window, origin);

      expect(measured.round(), reach, reason: '$window');
      expect(
        waveDuration(measured).inMilliseconds,
        closeTo(millis, 1),
        reason: '$window',
      );
      expect(hueWidth(window), closeTo(hue, 0.05), reason: '$window');
    }
  });

  test("the wave's band and the hue's width stay within their bounds", () {
    for (var reach = 0.0; reach <= 4000; reach += 25) {
      expect(waveBand(reach), inInclusiveRange(160, 320));
    }
    for (var side = 100.0; side <= 3000; side += 25) {
      expect(hueWidth(Size(side, side * 2)), inInclusiveRange(20, 32));
    }
  });
}
