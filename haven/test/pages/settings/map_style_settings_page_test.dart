/// Widget tests for [MapStyleSettingsPage] and [mapStyleLabel].
///
/// Verifies the options render, the current selection is reflected, tapping a
/// choice updates the [mapStyleControllerProvider] and persists it, and the
/// page never uses location-privacy vocabulary (changing the basemap must not
/// imply a change to who can see the user).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/pages/settings/map_style_settings_page.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _wrap({MapStyleSelection initial = const MapStyleSelection.auto()}) {
  return ProviderScope(
    overrides: [
      mapStyleControllerProvider.overrideWith(
        (ref) => MapStyleController(initial),
      ),
    ],
    child: const MaterialApp(home: MapStyleSettingsPage()),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mapStyleLabel', () {
    test('returns the human-readable label for each option', () {
      expect(mapStyleLabel(const MapStyleSelection.auto()), 'Auto');
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdOsmBright)),
        'Detailed',
      );
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdOutdoors)),
        'Outdoors',
      );
    });

    test('falls back to Auto for a selection not exposed as a row', () {
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdAlidadeSmoothDark)),
        'Auto',
      );
    });
  });

  group('MapStyleSettingsPage', () {
    testWidgets('renders the three options', (tester) async {
      await tester.pumpWidget(_wrap());

      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Detailed'), findsOneWidget);
      expect(find.text('Outdoors'), findsOneWidget);
      expect(
        find.byType(RadioListTile<MapStyleSelection>),
        findsNWidgets(3),
      );
    });

    testWidgets('marks the current selection as checked', (tester) async {
      await tester.pumpWidget(
        _wrap(initial: const MapStyleSelection.style(kStyleIdOutdoors)),
      );

      final group = tester.widget<RadioGroup<MapStyleSelection>>(
        find.byType(RadioGroup<MapStyleSelection>),
      );
      expect(
        group.groupValue,
        const MapStyleSelection.style(kStyleIdOutdoors),
      );
    });

    testWidgets('tapping a choice updates provider state', (tester) async {
      await tester.pumpWidget(_wrap());

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapStyleSettingsPage)),
      );

      await tester.tap(find.text('Detailed'));
      await tester.pumpAndSettle();

      expect(
        container.read(mapStyleControllerProvider),
        const MapStyleSelection.style(kStyleIdOsmBright),
      );
    });

    testWidgets('tapping a choice persists the selection', (tester) async {
      await tester.pumpWidget(_wrap());

      await tester.tap(find.text('Outdoors'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kMapStyleKey), kStyleIdOutdoors);
    });

    testWidgets('re-tapping the active row writes nothing', (tester) async {
      await tester.pumpWidget(
        _wrap(initial: const MapStyleSelection.style(kStyleIdOutdoors)),
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MapStyleSettingsPage)),
      );

      await tester.tap(find.text('Outdoors'));
      await tester.pumpAndSettle();

      // The controller is a no-op on an unchanged selection, so neither the
      // state nor the persisted value changes (nothing was written this run).
      expect(
        container.read(mapStyleControllerProvider),
        const MapStyleSelection.style(kStyleIdOutdoors),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kMapStyleKey), isNull);
    });

    testWidgets('uses no location-privacy vocabulary', (tester) async {
      await tester.pumpWidget(_wrap());

      for (final term in const [
        'exact',
        'precise',
        'hidden',
        'visible',
        'share',
        'location',
      ]) {
        expect(
          find.textContaining(term),
          findsNothing,
          reason: 'unexpected privacy term "$term" on the map-style page',
        );
      }
    });
  });
}
