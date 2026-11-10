/// Tests for shared marker metrics: palette and initials.
///
/// The size no-pop match (`kDropletFullDiameter == kRingDiameter`)
/// is guarded in `marker_geometry_test.dart`.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

void main() {
  group('avatarPaletteIndex', () {
    test('is the first byte mod 8', () {
      expect(avatarPaletteIndex('00${'a' * 62}'), 0);
      expect(avatarPaletteIndex('08${'a' * 62}'), 0);
      expect(avatarPaletteIndex('01${'a' * 62}'), 1);
      expect(avatarPaletteIndex('ff${'0' * 62}'), 7);
      expect(avatarPaletteIndex('FF${'0' * 62}'), 7);
    });

    test('is deterministic and ignores everything past the first byte', () {
      final a = 'c3${'1' * 62}';
      final b = 'c3${'e' * 62}';
      expect(avatarPaletteIndex(a), avatarPaletteIndex(a));
      expect(avatarPaletteIndex(a), avatarPaletteIndex(b));
    });

    test('is total: never throws and stays within the palette', () {
      for (final key in [
        '',
        'a',
        '7',
        'zz${'0' * 62}',
        'g1',
        '-1',
        '🦊🦊',
        'deadbeef0123',
        'ab' * 32,
      ]) {
        final i = avatarPaletteIndex(key);
        expect(i, inInclusiveRange(0, kAvatarPalette.length - 1), reason: key);
      }
    });

    test('a non-hex prefix falls back to the code-unit sum mod 8', () {
      // 'z' = 122, so 'zz' sums to 244 and 244 % 8 = 4.
      expect(avatarPaletteIndex('zz'), 4);
      expect(avatarPaletteIndex(''), 0);
      expect(avatarPaletteIndex('a'), 97 % 8);
    });
  });

  group('kAvatarPalette', () {
    double contrast(Color a, Color b) {
      final la = a.computeLuminance();
      final lb = b.computeLuminance();
      final hi = la > lb ? la : lb;
      final lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    test('has exactly eight pairwise-distinct entries', () {
      expect(kAvatarPalette, hasLength(8));
      final tops = kAvatarPalette.map((e) => e.top.toARGB32()).toSet();
      final bottoms = kAvatarPalette.map((e) => e.bottom.toARGB32()).toSet();
      expect(tops, hasLength(8));
      expect(bottoms, hasLength(8));
    });

    test('white initials clear WCAG AA on both stops of every entry', () {
      for (final (i, e) in kAvatarPalette.indexed) {
        expect(kAvatarInitialsColor, Colors.white);
        expect(contrast(kAvatarInitialsColor, e.top), greaterThanOrEqualTo(4.5),
            reason: 'top of entry $i');
        expect(
          contrast(kAvatarInitialsColor, e.bottom),
          greaterThanOrEqualTo(4.5),
          reason: 'bottom of entry $i',
        );
      }
    });

    test('each entry is a barely-visible top-lighter gradient in a tight band',
        () {
      for (final (i, e) in kAvatarPalette.indexed) {
        expect(
          e.top.computeLuminance(),
          greaterThan(e.bottom.computeLuminance()),
          reason: 'entry $i',
        );
        for (final c in [e.top, e.bottom]) {
          expect(c.computeLuminance(), inInclusiveRange(0.06, 0.20),
              reason: 'entry $i');
        }
      }
    });

    test('every constant regenerates from its documented OKLCH spec', () {
      // (hue index k, top chroma, bottom chroma): L 0.52 top, 0.45 bottom,
      // hue 20 + 45k, chroma 0.10 unless the entry comment says it was
      // reduced to fit sRGB.
      const chromas = <(double, double)>[
        (0.10, 0.10),
        (0.10, 0.10),
        (0.10, 0.098),
        (0.10, 0.10),
        (0.088, 0.0765),
        (0.10, 0.10),
        (0.10, 0.10),
        (0.10, 0.10),
      ];
      for (final (k, (topC, bottomC)) in chromas.indexed) {
        final hue = 20.0 + 45.0 * k;
        _expectWithinTwo(kAvatarPalette[k].top, _oklchToSrgb(0.52, topC, hue),
            'top $k');
        _expectWithinTwo(
          kAvatarPalette[k].bottom,
          _oklchToSrgb(0.45, bottomC, hue),
          'bottom $k',
        );
      }
    });

    test('avatarPaletteFor reads the entry at avatarPaletteIndex', () {
      for (final key in ['00ab', '07', 'ff', 'zz', '']) {
        expect(
          identical(
            avatarPaletteFor(key),
            kAvatarPalette[avatarPaletteIndex(key)],
          ),
          isTrue,
        );
      }
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
}

/// Björn Ottosson's OKLab -> linear sRGB -> sRGB, as 8-bit channels.
List<int> _oklchToSrgb(double l, double c, double hueDegrees) {
  final h = hueDegrees * math.pi / 180;
  final a = c * math.cos(h);
  final b = c * math.sin(h);
  final l_ = l + 0.3963377774 * a + 0.2158037573 * b;
  final m_ = l - 0.1055613458 * a - 0.0638541728 * b;
  final s_ = l - 0.0894841775 * a - 1.2914855480 * b;
  final lc = l_ * l_ * l_;
  final mc = m_ * m_ * m_;
  final sc = s_ * s_ * s_;
  final linear = [
    4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
    -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
    -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
  ];
  return [
    for (final v in linear)
      (255 *
              (v <= 0.0031308
                  ? 12.92 * v
                  : 1.055 * math.pow(v, 1 / 2.4) - 0.055))
          .clamp(0, 255)
          .round(),
  ];
}

void _expectWithinTwo(Color actual, List<int> expected, String reason) {
  final got = [
    (actual.r * 255).round(),
    (actual.g * 255).round(),
    (actual.b * 255).round(),
  ];
  for (var i = 0; i < 3; i++) {
    expect((got[i] - expected[i]).abs(), lessThanOrEqualTo(2),
        reason: '$reason channel $i: got $got, spec $expected');
  }
}
