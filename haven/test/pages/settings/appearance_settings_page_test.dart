/// Widget tests for [AppearanceSettingsPage].
///
/// Verifies the renamed page renders the three theme choices and the language
/// row, reflects the current theme, and that tapping a theme choice updates the
/// [themeModeControllerProvider] state and the persisted [SharedPreferences]
/// entry. Tapping the language row opens [LanguageSettingsPage].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/appearance_settings_page.dart';
import 'package:haven/src/pages/settings/language_settings_page.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';

Future<void> _pump(
  WidgetTester tester, {
  ThemeMode initial = ThemeMode.system,
}) {
  return pumpLocalized(
    tester,
    const AppearanceSettingsPage(),
    overrides: [
      themeModeControllerProvider.overrideWith(
        (ref) => ThemeModeController(initial),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('renders the title, three theme options, and language row', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.widgetWithText(AppBar, 'Appearance'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
    expect(
      find.widgetWithText(RadioListTile<ThemeMode>, 'System default'),
      findsOneWidget,
    );
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    // The language row (defaults to "System default" when no override is set).
    expect(find.widgetWithText(ListTile, 'Language'), findsOneWidget);
  });

  testWidgets('marks the current theme as selected', (tester) async {
    await _pump(tester, initial: ThemeMode.dark);

    final group = tester.widget<RadioGroup<ThemeMode>>(
      find.byType(RadioGroup<ThemeMode>),
    );
    expect(group.groupValue, ThemeMode.dark);
  });

  testWidgets('tapping a theme updates provider state and persists it', (
    tester,
  ) async {
    await _pump(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AppearanceSettingsPage)),
    );

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeControllerProvider), ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kThemeModeKey), 'dark');
  });

  testWidgets('tapping the language row opens the language page', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.text('Language'));
    await tester.pumpAndSettle();

    expect(find.byType(LanguageSettingsPage), findsOneWidget);
  });
}
