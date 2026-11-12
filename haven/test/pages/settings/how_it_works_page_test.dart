/// Widget tests for [HowItWorksPage].
///
/// The page is long-form copy, so the promises worth pinning are structural:
/// every `howItWorks*` string the ARB carries is on the page (none orphaned,
/// none hard-coded), the section titles are real headings for screen readers,
/// the story reads in its intended order, and it lays out in every shipped
/// locale, right-to-left included, up to a 200% text scale.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/how_it_works_page.dart';
import 'package:haven/src/widgets/common/section_header.dart';

import '../../helpers/english_arb.dart';
import '../../helpers/localized_app_harness.dart';

/// Every `howItWorks*` message key in the English template, in file order.
List<String> _pageKeys() {
  final arb =
      jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
          as Map<String, dynamic>;
  return arb.keys.where((k) => k.startsWith('howItWorks')).toList();
}

const _rtlLanguages = {'ar', 'fa', 'ur'};

void _usePhoneSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 690);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows every howItWorks string the ARB carries, once', (
    tester,
  ) async {
    await pumpLocalized(tester, const HowItWorksPage());

    final keys = _pageKeys();
    // Title, intro, 8 headings and 17 paragraphs: a floor, so an emptied
    // extractor cannot pass this vacuously.
    expect(keys.length, greaterThanOrEqualTo(27));
    for (final key in keys) {
      expect(
        find.text(englishArb(key)),
        findsOneWidget,
        reason: '$key is in the ARB but not rendered on the page',
      );
    }
  });

  testWidgets('section titles are level-2 headings for screen readers', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpLocalized(tester, const HowItWorksPage());

    final headers = tester.widgetList<HavenSectionHeader>(
      find.byType(HavenSectionHeader),
    );
    final headingKeys = _pageKeys().where((k) => k.endsWith('Heading'));
    expect(
      headers.map((h) => h.label),
      headingKeys.map(englishArb).toList(),
      reason: 'every section heading, in the order the ARB lists them',
    );
    for (final header in headers) {
      final node = tester.getSemantics(find.text(header.label));
      expect(node.flagsCollection.isHeader, isTrue, reason: header.label);
      expect(node.headingLevel, 2, reason: header.label);
    }
    handle.dispose();
  });

  testWidgets('reads in the order the ARB lists the copy', (tester) async {
    await pumpLocalized(tester, const HowItWorksPage());

    final bodyKeys = _pageKeys().where((k) => k != 'howItWorksTitle');
    var previous = double.negativeInfinity;
    for (final key in bodyKeys) {
      final top = tester.getTopLeft(find.text(englishArb(key))).dy;
      expect(top, greaterThan(previous), reason: '$key is out of order');
      previous = top;
    }
  });

  testWidgets('the last paragraph can be scrolled into view', (tester) async {
    _usePhoneSurface(tester);
    await pumpLocalized(tester, const HowItWorksPage());

    // A real drag, so the test fails if the page stops scrolling; the column
    // builds every paragraph up front, so only hit-testability tells
    // on-screen from off-screen.
    final last = find.text(englishArb(_pageKeys().last)).hitTestable();
    expect(last, findsNothing);
    await tester.dragUntilVisible(
      last,
      find.byType(SingleChildScrollView),
      const Offset(0, -300),
    );
    expect(last, findsOneWidget);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;

    group('locale "$code"', () {
      for (final scale in [1.0, 2.0]) {
        testWidgets('lays out without overflow at ${scale}x text', (
          tester,
        ) async {
          _usePhoneSurface(tester);
          await pumpLocalized(
            tester,
            const HowItWorksPage(),
            locale: locale,
            textScaler: TextScaler.linear(scale),
          );
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets("lays its own text out in this locale's direction", (
        tester,
      ) async {
        await pumpLocalized(tester, const HowItWorksPage(), locale: locale);
        final expected = _rtlLanguages.contains(code)
            ? TextDirection.rtl
            : TextDirection.ltr;
        final l10n = l10nOf(tester, HowItWorksPage);
        for (final text in [
          l10n.howItWorksIntro,
          l10n.howItWorksLimitsHeading,
        ]) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text(text),
          );
          expect(paragraph.textDirection, expected, reason: text);
        }
      });
    });
  }
}
