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
import 'package:haven/src/pages/onboarding/welcome_screen.dart';
import 'package:haven/src/pages/settings/appearance_settings_page.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/localized_app_harness.dart';

/// Language codes that must lay out right-to-left.
const _rtlLanguages = {'ar', 'fa', 'ur'};

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

      testWidgets('WelcomeScreen lays out without overflow', (tester) async {
        _usePhoneSurface(tester);
        await pumpLocalized(tester, const WelcomeScreen(), locale: locale);
        expect(tester.takeException(), isNull);
      });

      if (_rtlLanguages.contains(code)) {
        testWidgets('renders right-to-left', (tester) async {
          await pumpLocalized(tester, const WelcomeScreen(), locale: locale);
          final dir = Directionality.of(
            tester.element(find.byType(WelcomeScreen)),
          );
          expect(dir, TextDirection.rtl);
        });
      }
    });
  }

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
    }
  });
}
