/// Widget tests for [MapStyleSettingsPage] and [mapStyleLabel].
///
/// Verifies the options render, the current selection is reflected, tapping a
/// choice updates the [mapStyleControllerProvider] and persists it, and the
/// page never uses location-privacy vocabulary (changing the basemap must not
/// imply a change to who can see the user).
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
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
      expect(mapStyleLabel(const MapStyleSelection.auto()), 'Minimal');
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdOsmBright)),
        'Detailed',
      );
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdOutdoors)),
        'Outdoors',
      );
    });

    test('falls back to Minimal for a selection not exposed as a row', () {
      expect(
        mapStyleLabel(const MapStyleSelection.style(kStyleIdAlidadeSmoothDark)),
        'Minimal',
      );
    });
  });

  group('MapStyleSettingsPage', () {
    testWidgets('renders the three options', (tester) async {
      await tester.pumpWidget(_wrap());

      expect(find.text('Minimal'), findsOneWidget);
      expect(find.text('Detailed'), findsOneWidget);
      expect(find.text('Outdoors'), findsOneWidget);
      // Subtitles too, so a copy regression is caught.
      expect(
        find.text('Calm, low-detail canvas that follows your light or dark '
            'theme'),
        findsOneWidget,
      );
      expect(
        find.text('Full-colour streets, labels, and places'),
        findsOneWidget,
      );
      expect(
        find.text('Shaded terrain with trails and parks'),
        findsOneWidget,
      );
      expect(
        find.byType(RadioListTile<MapStyleSelection>),
        findsNWidgets(3),
      );
    });

    testWidgets('shows placeholder previews (no network) without a key', (
      tester,
    ) async {
      // No STADIA_API_KEY is injected in tests, so the previews must render the
      // neutral placeholder and never build a network-backed map.
      await tester.pumpWidget(_wrap());

      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('City'), findsOneWidget);
      expect(find.text('Nature'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      // All 6 previews (2 scenes x 3 styles) are mounted so every style's tiles
      // prefetch on entry; each renders the placeholder when no key is set.
      // (skipOffstage:false counts the IndexedStack's unpainted children too.)
      expect(
        find.text('Live preview appears in release builds', skipOffstage: false),
        findsNWidgets(6),
      );
      // IndexedStack paints only the selected style, so 2 scenes are visible.
      expect(
        find.text('Live preview appears in release builds'),
        findsNWidgets(2),
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
