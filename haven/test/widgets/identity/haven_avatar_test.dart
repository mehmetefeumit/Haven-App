/// Widget tests for [HavenAvatar] grapheme-safe initials rendering.
///
/// Verifies that emoji, flag sequences, ZWJ clusters, Cyrillic, Arabic, and
/// CJK initials are shown correctly instead of "?" replacement glyphs.
/// The bug was Dart String.substring(0, 2) / String[0] counting UTF-16 code
/// units rather than Unicode grapheme clusters, splitting surrogate pairs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// Pumps a [HavenAvatar] with the given [initials] and returns the [Text]
/// widget that the fallback path renders inside the avatar circle.
Future<Text> _pumpAndFindInitialsText(
  WidgetTester tester,
  String? initials,
) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: HavenAvatar(initials: initials, publicKey: 'deadbeef0123'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.widget<Text>(
    find.descendant(
      of: find.byType(HavenAvatar),
      matching: find.byType(Text),
    ),
  );
}

void main() {
  group('HavenAvatar initials — grapheme-safe rendering', () {
    testWidgets('null initials renders "?" fallback', (tester) async {
      final text = await _pumpAndFindInitialsText(tester, null);
      expect(text.data, '?');
    });

    testWidgets('empty initials renders empty string', (tester) async {
      final text = await _pumpAndFindInitialsText(tester, '');
      expect(text.data, '');
    });

    testWidgets('single Latin letter is uppercased', (tester) async {
      final text = await _pumpAndFindInitialsText(tester, 'a');
      expect(text.data, 'A');
    });

    testWidgets('two Latin letters are both uppercased', (tester) async {
      final text = await _pumpAndFindInitialsText(tester, 'jd');
      expect(text.data, 'JD');
    });

    testWidgets(
      'emoji initial is preserved as a single grapheme cluster, not split',
      (tester) async {
        // '🎉' is U+1F389 — a surrogate pair in UTF-16.
        // substring(0,2) today grabs TWO code units = the whole emoji by
        // accident on some engines, but [0] gives a lone surrogate → '?'.
        // The correct fix keeps exactly one grapheme cluster.
        final text = await _pumpAndFindInitialsText(tester, '🎉');
        // After uppercase (no-op for emoji) and grapheme-safe take(2):
        // the result must be the emoji itself, not '?' or a broken character.
        expect(text.data, isNot('?'));
        expect(text.data, '🎉');
      },
    );

    testWidgets(
      'two-character emoji initials keeps both emoji as separate graphemes',
      (tester) async {
        // e.g. '🎉A' — avatar should show both grapheme clusters.
        final text = await _pumpAndFindInitialsText(tester, '🎉A');
        expect(text.data, '🎉A');
      },
    );

    testWidgets(
      'ZWJ family emoji is treated as one grapheme cluster, not split',
      (tester) async {
        // '👨‍👩‍👧' consists of multiple code points joined by ZWJ (U+200D).
        // Byte-based substring splits this into mojibake / '?'.
        final text = await _pumpAndFindInitialsText(tester, '👨‍👩‍👧');
        expect(text.data, isNot('?'));
        expect(text.data, '👨‍👩‍👧');
      },
    );

    testWidgets(
      'regional-indicator flag is treated as one grapheme cluster',
      (tester) async {
        // '🇺🇸' is two regional-indicator code points — one grapheme.
        final text = await _pumpAndFindInitialsText(tester, '🇺🇸');
        expect(text.data, isNot('?'));
        expect(text.data, '🇺🇸');
      },
    );

    testWidgets('Cyrillic initial is uppercased', (tester) async {
      final text = await _pumpAndFindInitialsText(tester, 'пм');
      expect(text.data, 'ПМ');
    });

    testWidgets('Arabic initial is preserved as first grapheme', (tester) async {
      // Arabic text — ensure no '?' from bad indexing.
      final text = await _pumpAndFindInitialsText(tester, 'مر');
      expect(text.data, isNot('?'));
      // Arabic uppercasing is a no-op, so grapheme count is what matters.
      expect(text.data!.characters.length, 2);
    });

    testWidgets('initials longer than 2 graphemes are capped at 2', (
      tester,
    ) async {
      final text = await _pumpAndFindInitialsText(tester, 'abc');
      // Must take at most 2 graphemes: 'AB'
      expect(text.data, 'AB');
    });
  });

  // -------------------------------------------------------------------------
  // Explicit diameter override — lets a caller size the avatar to match a
  // sibling widget (e.g. a Material CircleAvatar in the same list) instead of
  // the fixed HavenAvatarSize enum steps.
  // -------------------------------------------------------------------------

  group('HavenAvatar — explicit diameter override', () {
    testWidgets('diameter overrides the size enum', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: HavenAvatar(
                initials: 'AB',
                publicKey: 'deadbeef0123',
                // size says 32dp, but the explicit diameter must win.
                size: HavenAvatarSize.small,
                diameter: 40,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(HavenAvatar)), const Size(40, 40));
    });

    testWidgets('falls back to the size enum when no diameter is given', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: HavenAvatar(
                initials: 'AB',
                publicKey: 'deadbeef0123',
                size: HavenAvatarSize.small,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(HavenAvatar)), const Size(32, 32));
    });
  });

  group('HavenAvatar — palette disc (§7.5 A11Y)', () {
    const pubkey = 'deadbeef0123';

    Future<void> pump(WidgetTester tester, {String? publicKey}) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: HavenAvatar(initials: 'TL', publicKey: publicKey),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    BoxDecoration discDecoration(WidgetTester tester) {
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(HavenAvatar),
              matching: find.byType(Container),
            )
            .first,
      );
      return container.decoration! as BoxDecoration;
    }

    testWidgets('paints the vertical gradient of avatarPaletteFor(pubkey) '
        'with white initials', (tester) async {
      await pump(tester, publicKey: pubkey);

      final entry = avatarPaletteFor(pubkey);
      final decoration = discDecoration(tester);
      expect(decoration.shape, BoxShape.circle);
      final gradient = decoration.gradient! as LinearGradient;
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.colors, [entry.top, entry.bottom]);

      final text = tester.widget<Text>(
        find.descendant(
          of: find.byType(HavenAvatar),
          matching: find.byType(Text),
        ),
      );
      expect(text.style?.color, kAvatarInitialsColor);
    });

    testWidgets('keeps the neutral surface disc without a pubkey', (
      tester,
    ) async {
      for (final key in [null, '']) {
        await pump(tester, publicKey: key);

        final scheme = Theme.of(
          tester.element(find.byType(HavenAvatar)),
        ).colorScheme;
        final decoration = discDecoration(tester);
        expect(decoration.gradient, isNull);
        expect(decoration.color, scheme.surfaceContainerHigh);
        final text = tester.widget<Text>(
          find.descendant(
            of: find.byType(HavenAvatar),
            matching: find.byType(Text),
          ),
        );
        expect(text.style?.color, scheme.onSurface);
      }
    });
  });
}
