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

    // Emoji / non-Latin / multi-code-unit grapheme cluster cases.
    // These all fail today because the production code uses [0]/substring
    // which reads UTF-16 code units, not grapheme clusters.

    test('emoji first word + Latin second word yields emoji + letter', () {
      // '🎉' is a two-code-unit surrogate pair; [0] gives a broken half.
      expect(markerInitials('🎉 Alice', 'x'), '🎉A');
    });

    test('single emoji word yields the emoji grapheme', () {
      expect(markerInitials('🎉', 'x'), '🎉');
    });

    test('two adjacent emoji — treated as one word — yields first emoji only', () {
      // '😀😀' is a single whitespace-free token; only first grapheme expected.
      expect(markerInitials('😀😀', 'x'), '😀');
    });

    test('Cyrillic single word yields first Cyrillic grapheme', () {
      expect(markerInitials('Привет', 'x'), 'П');
    });

    test('Cyrillic two words yield their leading letters (case preserved)', () {
      // markerInitials must NOT uppercase; that is markerGlyph's job.
      expect(markerInitials('Привет Мир', 'x'), 'ПМ');
    });

    test('lowercase Cyrillic word is preserved as-is', () {
      expect(markerInitials('мир', 'x'), 'м');
    });

    test('Arabic single word yields first Arabic grapheme', () {
      expect(markerInitials('مرحبا', 'x'), 'م');
    });

    test('CJK single word yields first CJK grapheme', () {
      expect(markerInitials('日本語', 'x'), '日');
    });

    test('ZWJ family emoji first word + Latin second word yields cluster + letter', () {
      // '👨‍👩‍👧' is a ZWJ sequence counting as ONE grapheme cluster.
      expect(markerInitials('👨‍👩‍👧 Family', 'x'), '👨‍👩‍👧F');
    });

    test('regional-indicator flag first word + Latin second word yields flag + letter', () {
      // '🇺🇸' is two regional-indicator characters — ONE grapheme cluster.
      expect(markerInitials('🇺🇸 USA', 'x'), '🇺🇸U');
    });
  });

  group('markerGlyph', () {
    // markerGlyph does not exist yet — these tests must fail to compile / link.
    // Once the implementation is added, they document the full contract.

    test('two graphemes when diameter >= 40, uppercased', () {
      expect(markerGlyph('🎉A', 50), '🎉A');
    });

    test('one grapheme when diameter < 40', () {
      expect(markerGlyph('🎉A', 30), '🎉');
    });

    test('single emoji grapheme unchanged regardless of diameter', () {
      expect(markerGlyph('🎉', 50), '🎉');
    });

    test('Latin initials are uppercased', () {
      expect(markerGlyph('jd', 50), 'JD');
    });

    test('Latin initials truncated to one grapheme when small diameter', () {
      expect(markerGlyph('jd', 30), 'J');
    });

    test('Cyrillic initial is uppercased', () {
      expect(markerGlyph('п', 50), 'П');
    });

    test('ZWJ family emoji is not split across code units', () {
      // '👨‍👩‍👧' must survive toUpperCase() and be taken as a single grapheme.
      expect(markerGlyph('👨‍👩‍👧', 50), '👨‍👩‍👧');
    });

    test('ZWJ family emoji + letter at small diameter yields the family cluster', () {
      expect(markerGlyph('👨‍👩‍👧F', 30), '👨‍👩‍👧');
    });

    test('regional-indicator flag pair + letter at large diameter yields flag + letter', () {
      expect(markerGlyph('🇺🇸U', 50), '🇺🇸U');
    });

    test('empty string returns empty string', () {
      expect(markerGlyph('', 50), '');
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
