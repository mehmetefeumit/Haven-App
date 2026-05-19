/// Widget tests for [`ThemeSettingsPage`].
///
/// Verifies the three radio choices render, the current selection is
/// reflected, and tapping a choice updates the
/// [themeModeControllerProvider] state and the underlying
/// [SharedPreferences] entry.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/theme_settings_page.dart';
import 'package:haven/src/providers/theme_mode_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap({ThemeMode initial = ThemeMode.system}) {
  return ProviderScope(
    overrides: [
      themeModeControllerProvider.overrideWith(
        (ref) => ThemeModeController(initial),
      ),
    ],
    child: const MaterialApp(home: ThemeSettingsPage()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('themeModeLabel', () {
    test('returns the human-readable label for each ThemeMode', () {
      expect(themeModeLabel(ThemeMode.system), 'System default');
      expect(themeModeLabel(ThemeMode.light), 'Light');
      expect(themeModeLabel(ThemeMode.dark), 'Dark');
    });
  });

  group('ThemeSettingsPage', () {
    testWidgets('renders all three options', (tester) async {
      await tester.pumpWidget(_wrap());

      expect(find.text('System default'), findsOneWidget);
      expect(find.text('Light'), findsOneWidget);
      expect(find.text('Dark'), findsOneWidget);
      expect(find.byType(RadioListTile<ThemeMode>), findsNWidgets(3));
    });

    testWidgets('marks the currently selected mode as checked', (tester) async {
      await tester.pumpWidget(_wrap(initial: ThemeMode.dark));

      final group = tester.widget<RadioGroup<ThemeMode>>(
        find.byType(RadioGroup<ThemeMode>),
      );

      expect(group.groupValue, ThemeMode.dark);
    });

    testWidgets('tapping a choice updates provider state', (tester) async {
      await tester.pumpWidget(_wrap());

      final container = ProviderScope.containerOf(
        tester.element(find.byType(ThemeSettingsPage)),
      );

      await tester.tap(find.text('Dark'));
      await tester.pumpAndSettle();

      expect(container.read(themeModeControllerProvider), ThemeMode.dark);
    });

    testWidgets('tapping a choice persists the selection', (tester) async {
      await tester.pumpWidget(_wrap());

      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kThemeModeKey), 'light');
    });
  });
}
