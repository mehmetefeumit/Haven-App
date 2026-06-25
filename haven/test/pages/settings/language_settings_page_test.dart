/// Widget tests for [LanguageSettingsPage].
///
/// Verifies the picker lists "System default" plus each shipped locale (English
/// only in M1), marks the current selection, and that choosing a language
/// updates [localeControllerProvider] / [SharedPreferences] and returns to the
/// previous screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/settings/language_settings_page.dart';
import 'package:haven/src/providers/locale_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';

/// A trivial host that pushes [LanguageSettingsPage], so the page has a route
/// to pop back to when a language is chosen.
class _Host extends StatelessWidget {
  const _Host();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const LanguageSettingsPage(),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
  }
}

Future<void> _openPicker(
  WidgetTester tester, {
  Locale? initial,
}) async {
  await pumpLocalized(
    tester,
    const _Host(),
    overrides: [
      localeControllerProvider.overrideWith((ref) => LocaleController(initial)),
    ],
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('lists System default and each shipped locale', (tester) async {
    await _openPicker(tester);

    expect(find.text('System default'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('marks the current selection with a check', (tester) async {
    await _openPicker(tester, initial: const Locale('en'));

    // Exactly one row is selected → exactly one check icon.
    expect(find.byIcon(LucideIcons.check), findsOneWidget);
    expect(
      find.descendant(
        of: find.widgetWithText(ListTile, 'English'),
        matching: find.byIcon(LucideIcons.check),
      ),
      findsOneWidget,
    );
  });

  testWidgets('choosing a language persists it and returns to the host', (
    tester,
  ) async {
    await _openPicker(tester);

    // Capture the container from the onstage picker before the tap pops it.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LanguageSettingsPage)),
    );

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(container.read(localeControllerProvider), const Locale('en'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kLocaleKey), 'en');
    // Popped back to the host.
    expect(find.byType(LanguageSettingsPage), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('choosing System default clears the override', (tester) async {
    await _openPicker(tester, initial: const Locale('en'));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LanguageSettingsPage)),
    );

    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();

    expect(container.read(localeControllerProvider), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(kLocaleKey), isNull);
  });
}
