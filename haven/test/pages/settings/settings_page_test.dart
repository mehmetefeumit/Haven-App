/// Widget tests for [SettingsPage].
///
/// Locks the consolidation: a single "Identity" entry and no separate
/// "Your Profile" tile, with the other settings entries still present.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/settings_page.dart';
import 'package:haven/src/widgets/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The providers reached from this page read SharedPreferences; seed an
    // empty store so they build with defaults.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Widget build() => const ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SettingsPage(),
    ),
  );

  testWidgets('shows a single "Identity" entry', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(find.text('Identity'), findsOneWidget);
  });

  testWidgets('no longer shows a separate "Your Profile" entry', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(find.text('Your Profile'), findsNothing);
  });

  testWidgets('keeps the other settings entries', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    expect(find.text('Relays'), findsOneWidget);
    expect(find.text('Location'), findsOneWidget);
    expect(find.text('Map style'), findsOneWidget);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);
  });

  testWidgets('every hub row is title-only', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // Asserted on the tiles rather than on the removed strings, so a new row
    // that arrives with a subtitle fails here too. The debug-overlay switch is
    // a SwitchListTile and deliberately keeps its supporting line.
    final tiles = tester.widgetList<HavenSettingsTile>(
      find.byType(HavenSettingsTile),
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      expect(tile.subtitle, isNull, reason: '"${tile.title}" has a subtitle');
    }
  });
}
