/// Multi-locale layout smoke tests.
///
/// Renders key screens in EVERY shipped locale (via
/// [AppLocalizations.supportedLocales], so new languages are covered
/// automatically) and asserts:
///   * no layout overflow / render exception on a phone-width surface;
///   * right-to-left text direction for RTL locales (e.g. Arabic);
///   * no overflow for the longest locales at a large accessibility font scale.
///
/// This catches the classic i18n regressions — German/Arabic strings run
/// 30–50% longer than English, and large Dynamic Type compounds it — before a
/// real device does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/onboarding/intro_screen.dart';
import 'package:haven/src/pages/settings/appearance_settings_page.dart';
import 'package:haven/src/pages/settings/privacy_content.dart';
import 'package:haven/src/pages/settings/privacy_page.dart';
import 'package:haven/src/pages/settings/privacy_topic_page.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/localized_app_harness.dart';

/// Language codes that must lay out right-to-left.
const _rtlLanguages = {'ar', 'fa', 'ur'};

/// Locales the Privacy *topic* pages are swept in.
///
/// Deliberately a subset, and worth stating plainly: the Privacy topic pages
/// are the most prose-heavy surfaces in the app, so sweeping every topic in
/// every locale would multiply this suite several times over for little added
/// signal. These four are the worst cases — de and ru run 20–35% longer than
/// English, ar and fa add RTL on top of length. The Privacy *hub* is still
/// swept in every locale below, and every topic is covered at 320dp / 200%
/// scale in `privacy_topic_page_test.dart`.
const _privacyTopicSweepLanguages = ['de', 'ru', 'ar', 'fa'];

/// A narrow phone surface (logical 360×690) — overflow is far likelier here
/// than on the 800×600 test default, so this is where long translations bite.
void _usePhoneSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 690);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

List<Override> get _overrides => [
  themeModeControllerProvider.overrideWith(
    (ref) => ThemeModeController(ThemeMode.system),
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  for (final locale in AppLocalizations.supportedLocales) {
    final code = locale.languageCode;

    group('locale "$code"', () {
      testWidgets('AppearanceSettingsPage lays out without overflow', (
        tester,
      ) async {
        _usePhoneSurface(tester);
        await pumpLocalized(
          tester,
          const AppearanceSettingsPage(),
          locale: locale,
          overrides: _overrides,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('IntroScreen lays out without overflow', (tester) async {
        _usePhoneSurface(tester);
        await pumpLocalized(tester, const IntroScreen(), locale: locale);
        expect(tester.takeException(), isNull);
      });

      testWidgets('PrivacyPage lays out without overflow', (tester) async {
        _usePhoneSurface(tester);
        await pumpLocalized(tester, const PrivacyPage(), locale: locale);
        expect(tester.takeException(), isNull);
      });

      if (_rtlLanguages.contains(code)) {
        testWidgets('renders right-to-left', (tester) async {
          await pumpLocalized(tester, const IntroScreen(), locale: locale);
          final dir = Directionality.of(
            tester.element(find.byType(IntroScreen)),
          );
          expect(dir, TextDirection.rtl);
        });
      }
    });
  }

  // Prose-heavy Privacy topic pages in the longest and RTL locales. See
  // [_privacyTopicSweepLanguages] for why this is a sampled subset.
  group('privacy topics (long + RTL locales)', () {
    for (final code in _privacyTopicSweepLanguages) {
      final matches = AppLocalizations.supportedLocales.where(
        (l) => l.languageCode == code,
      );
      if (matches.isEmpty) continue;
      final locale = matches.first;

      for (final topic in PrivacyTopic.values) {
        testWidgets('${topic.name} "$code" lays out without overflow', (
          tester,
        ) async {
          _usePhoneSurface(tester);
          await pumpLocalized(
            tester,
            PrivacyTopicPage(topic: topic),
            locale: locale,
          );
          expect(tester.takeException(), isNull);
        });

        testWidgets('${topic.name} "$code" survives expanding the detail', (
          tester,
        ) async {
          // The collapsed region hides the longest paragraphs on the page, so
          // overflow that only appears once expanded would otherwise go unseen.
          _usePhoneSurface(tester);
          await pumpLocalized(
            tester,
            PrivacyTopicPage(topic: topic),
            locale: locale,
          );
          final l10n = l10nOf(tester, PrivacyTopicPage);
          // The section sits below the fold on a 360×690 surface, and a
          // ListView builds no element for an off-screen child, so it must be
          // scrolled into view before it can be tapped.
          final header = find.text(l10n.privacyMoreDetailLabel);
          await tester.scrollUntilVisible(header, 200);
          await tester.tap(header);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  // The longest-rendering locales at a large accessibility font scale — the
  // worst case for clipping. German compounds run long; Arabic adds RTL.
  group('large text scale (1.5x)', () {
    for (final code in const ['de', 'ar']) {
      final matches = AppLocalizations.supportedLocales.where(
        (l) => l.languageCode == code,
      );
      if (matches.isEmpty) continue;
      final locale = matches.first;

      testWidgets('AppearanceSettingsPage "$code" at 1.5x has no overflow', (
        tester,
      ) async {
        _usePhoneSurface(tester);
        await pumpLocalized(
          tester,
          const AppearanceSettingsPage(),
          locale: locale,
          overrides: _overrides,
          textScaler: const TextScaler.linear(1.5),
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets('PrivacyPage "$code" at 1.5x has no overflow', (
        tester,
      ) async {
        _usePhoneSurface(tester);
        await pumpLocalized(
          tester,
          const PrivacyPage(),
          locale: locale,
          textScaler: const TextScaler.linear(1.5),
        );
        expect(tester.takeException(), isNull);
      });

      for (final topic in PrivacyTopic.values) {
        testWidgets('${topic.name} "$code" at 1.5x has no overflow', (
          tester,
        ) async {
          _usePhoneSurface(tester);
          await pumpLocalized(
            tester,
            PrivacyTopicPage(topic: topic),
            locale: locale,
            textScaler: const TextScaler.linear(1.5),
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
