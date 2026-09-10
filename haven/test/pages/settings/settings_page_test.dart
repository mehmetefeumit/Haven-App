/// Widget tests for [SettingsPage].
///
/// Locks the consolidation: a single "Identity" entry and no separate
/// "Your Profile" tile, with the other settings entries still present.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/settings/settings_page.dart';
import 'package:haven/src/providers/background_location_provider.dart';
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

  testWidgets('every hub row but Location is title-only', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // Asserted on the tiles rather than on the removed strings, so a new row
    // that arrives with a subtitle fails here too. The debug-overlay switch is
    // a SwitchListTile and deliberately keeps its supporting line.
    //
    // Location is the ONE exception, and it is named rather than allowed by
    // shape: it is the only setting whose state has no other standing surface
    // (a confirmed-Always iPhone shows no blue bar), so the row reports it.
    // Its own value is asserted below.
    final tiles = tester.widgetList<HavenSettingsTile>(
      find.byType(HavenSettingsTile),
    );
    expect(tiles, isNotEmpty);
    for (final tile in tiles) {
      if (tile.title == 'Location') {
        expect(tile.subtitle, isNotNull, reason: 'the one row that reports');
        continue;
      }
      expect(tile.subtitle, isNull, reason: '"${tile.title}" has a subtitle');
    }
  });

  /// The Location row's subtitle reports the background-sharing SETTING.
  ///
  /// Not service health, and not a platform behaviour: it is read straight off
  /// [backgroundSharingProvider], so it says what the user chose and stays
  /// true on both platforms. With the blue pill gone for confirmed-Always
  /// users, it is the only at-a-glance signal that Haven keeps sharing after
  /// they leave it.
  group('the Location row subtitle', () {
    const on = 'Background sharing on';
    const off = 'Only while Haven is open';

    /// The subtitle currently rendered on the Location row.
    String locationSubtitle(WidgetTester tester) => tester
        .widgetList<HavenSettingsTile>(find.byType(HavenSettingsTile))
        .firstWhere((t) => t.title == 'Location')
        .subtitle!;

    testWidgets('reads "only while open" while the setting is off', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(locationSubtitle(tester), off);
      expect(find.text(on), findsNothing);
    });

    testWidgets('reads "background sharing on" while the setting is on', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      expect(locationSubtitle(tester), on);
      expect(find.text(off), findsNothing);
    });

    testWidgets('follows the provider, so a change made elsewhere shows here', (
      tester,
    ) async {
      // The realistic path: the user flips the toggle on the Location page and
      // comes back. A subtitle resolved once at build would keep reporting the
      // old state until the hub was rebuilt from scratch.
      SharedPreferences.setMockInitialValues(<String, Object>{});

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      expect(locationSubtitle(tester), off);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SettingsPage)),
      );
      await container
          .read(backgroundSharingProvider.notifier)
          .setEnabled(enabled: true);
      await tester.pumpAndSettle();

      expect(locationSubtitle(tester), on);
    });

    testWidgets('is announced as part of the row, not as a stray line', (
      tester,
    ) async {
      // A hub row has no toggle state to announce, so the subtitle has to
      // reach the screen reader as part of the row's own name — otherwise the
      // one signal that background sharing is on is a separate swipe away
      // from the row it describes.
      final handle = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues(<String, Object>{
        kBackgroundSharingKey: true,
        kLocationDisclosureBackgroundAcceptedKey: true,
      });

      await tester.pumpWidget(build());
      await tester.pumpAndSettle();

      final node = tester.getSemantics(find.text(on));
      expect(node.label, contains('Location'));
      expect(node.label, contains(on));

      handle.dispose();
    });
  });
}
