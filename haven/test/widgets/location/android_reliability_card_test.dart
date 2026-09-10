/// Layout tests for [AndroidReliabilityCard].
///
/// The card lives behind `Platform.isAndroid` in `LocationSettingsPage`, which
/// a widget test on the Linux host cannot enter — which is exactly why its
/// heading could ship clamped to one ellipsized line and be clipped, today, in
/// four shipped locales without any test noticing. Rendering the card directly
/// is what makes that visible here instead of on a user's phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/location/android_reliability_card.dart';

/// A narrow-but-common phone: the width the guidance has to survive.
const _kPhone = Size(360, 800);

/// Pumps the card exactly as `LocationSettingsPage` lays it out — same page
/// padding, same theme — so the width measured here is the width on screen.
Future<void> _pumpCard(
  WidgetTester tester, {
  required Locale locale,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view
    ..physicalSize = _kPhone
    ..devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      theme: HavenTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScaler.scale(1),
        maxScaleFactor: textScaler.scale(1),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(HavenSpacing.base),
          children: const [AndroidReliabilityCard()],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The rendered heading paragraph.
RenderParagraph _heading(WidgetTester tester, BuildContext context) {
  return tester.renderObject<RenderParagraph>(
    find.text(AppLocalizations.of(context).locationSettingsAndroidHeader),
  );
}

/// The card's [BuildContext], for resolving the heading's own localization.
BuildContext _cardContext(WidgetTester tester) =>
    tester.element(find.byType(AndroidReliabilityCard));

/// Whether [paragraph] took more than one line.
///
/// Its laid-out height against the height the same text would take with no
/// width limit at all, which for a single sentence is exactly one line.
bool _wraps(RenderParagraph paragraph) =>
    paragraph.size.height >
    paragraph.getMaxIntrinsicHeight(double.infinity) + 0.5;

void main() {
  group('AndroidReliabilityCard heading', () {
    testWidgets('is never truncated, in any shipped locale', (tester) async {
      for (final locale in AppLocalizations.supportedLocales) {
        await _pumpCard(tester, locale: locale);
        expect(
          _heading(tester, _cardContext(tester)).didExceedMaxLines,
          isFalse,
          reason: 'the $locale heading is cut off on a 360 dp phone',
        );
      }
    });

    testWidgets('is never truncated at a 200 % text scale', (tester) async {
      // The accessibility floor: at the largest scale Android and iOS offer,
      // ~130 dp of text width is left per line, and every shipped heading
      // needs several lines.
      for (final locale in AppLocalizations.supportedLocales) {
        await _pumpCard(
          tester,
          locale: locale,
          textScaler: const TextScaler.linear(2),
        );
        expect(
          _heading(tester, _cardContext(tester)).didExceedMaxLines,
          isFalse,
          reason: 'the $locale heading is cut off at a 200 % text scale',
        );
      }
    });

    testWidgets('really does need more than one line — the width binds', (
      tester,
    ) async {
      // Anti-vacuity for the two tests above: `didExceedMaxLines` is false for
      // free when nothing wraps. The card leaves ~260 dp for the heading
      // (360 − 2×16 page padding − 2×4 card margin − 2×16 card padding − 20
      // icon − 8 gap), which fits roughly 34 characters of `titleSmall`, and
      // the shipped pt (49 characters), tr (42), es (41) and de (39) headings
      // are longer than that. Those users read a clipped heading under the
      // one-line clamp this card no longer has.
      final wrapping = <Locale>[];
      for (final locale in AppLocalizations.supportedLocales) {
        await _pumpCard(tester, locale: locale);
        if (_wraps(_heading(tester, _cardContext(tester)))) {
          wrapping.add(locale);
        }
      }
      expect(
        wrapping,
        isNotEmpty,
        reason: 'no shipped heading wraps at the default text scale, so the '
            'no-truncation tests above would pass even with a one-line clamp '
            'back in place — re-derive them against a width that binds',
      );
    });

    testWidgets('English wraps rather than clips at a 200 % text scale', (
      tester,
    ) async {
      // The scale-driven half of the same proof, in the shortest locale that
      // ships: even 27 characters cannot fit one line here, so no future copy
      // trim can make the clamp look harmless.
      await _pumpCard(
        tester,
        locale: const Locale('en'),
        textScaler: const TextScaler.linear(2),
      );
      final paragraph = _heading(tester, _cardContext(tester));
      expect(_wraps(paragraph), isTrue);
      expect(paragraph.didExceedMaxLines, isFalse);
    });
  });
}
