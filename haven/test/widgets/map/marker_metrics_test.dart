/// Tests for shared marker metrics: hue, initials, and contrast foreground.
///
/// Both the layer (which supplies a marker's `fillColor`) and any other caller
/// derive the hue from [avatarHue] here, so a member reads as the same colour
/// everywhere. The size no-pop match (`kDropletFullDiameter == kRingDiameter`)
/// is guarded in `marker_geometry_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

void main() {
  final scheme = ThemeData.light().colorScheme;

  group('avatarHue', () {
    test('is deterministic for a given pubkey', () {
      expect(avatarHue('abc123', scheme), avatarHue('abc123', scheme));
    });

    test('falls back to a surface tone when no key is available', () {
      expect(avatarHue(null, scheme), scheme.surfaceContainerHigh);
      expect(avatarHue('', scheme), scheme.surfaceContainerHigh);
    });
  });

  group('markerInitials', () {
    test('two words yield their leading letters', () {
      expect(markerInitials('Jane Doe', 'x'), 'JD');
    });

    test('one word yields its first letter', () {
      expect(markerInitials('Jane', 'x'), 'J');
    });

    test('no name falls back to the pubkey prefix', () {
      expect(markerInitials(null, 'abcdef'), 'ab');
    });

    test('a one-character pubkey is returned whole', () {
      expect(markerInitials(null, 'a'), 'a');
    });
  });

  group('onAvatarColor', () {
    test('dark foreground on a light background', () {
      expect(onAvatarColor(const Color(0xFFFFFFFF)), Colors.black);
    });

    test('white foreground on a dark background', () {
      expect(onAvatarColor(const Color(0xFF000000)), Colors.white);
    });

    test('chosen foreground clears WCAG AA across the avatar hue wheel', () {
      double contrast(Color a, Color b) {
        final la = a.computeLuminance();
        final lb = b.computeLuminance();
        final hi = la > lb ? la : lb;
        final lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      for (var hue = 0; hue < 360; hue += 5) {
        final bg = HSLColor.fromAHSL(1, hue.toDouble(), 0.35, 0.55).toColor();
        expect(
          contrast(onAvatarColor(bg), bg),
          greaterThanOrEqualTo(4.5),
          reason: 'hue $hue must clear AA for the small initials',
        );
      }
    });
  });
}
