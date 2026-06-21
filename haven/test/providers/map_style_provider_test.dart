/// Tests for [mapStyleControllerProvider] and [MapStyleSelection].
///
/// Asserts the same persistence invariant as the theme-mode controller (the
/// [SharedPreferences] write completes *before* the in-memory state mutates)
/// and the brightness resolution used by the map.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MapStyleSelection.resolve', () {
    test('auto resolves to alidade_smooth in light', () {
      expect(
        const MapStyleSelection.auto().resolve(Brightness.light),
        same(stadiaAlidadeSmooth),
      );
    });

    test('auto resolves to alidade_smooth_dark in dark', () {
      expect(
        const MapStyleSelection.auto().resolve(Brightness.dark),
        same(stadiaAlidadeSmoothDark),
      );
    });

    test('an explicit style resolves regardless of brightness', () {
      const selection = MapStyleSelection.style(kStyleIdOsmBright);
      expect(selection.resolve(Brightness.light), same(stadiaOsmBright));
      expect(selection.resolve(Brightness.dark), same(stadiaOsmBright));
    });

    test('an unknown id falls back to the brightness-appropriate canvas', () {
      const selection = MapStyleSelection.style('not_a_real_style');
      expect(selection.resolve(Brightness.light), same(stadiaAlidadeSmooth));
      expect(selection.resolve(Brightness.dark), same(stadiaAlidadeSmoothDark));
    });
  });

  group('MapStyleSelection equality', () {
    test('auto equals auto', () {
      expect(const MapStyleSelection.auto(), const MapStyleSelection.auto());
    });

    test('the same explicit id are equal', () {
      expect(
        const MapStyleSelection.style(kStyleIdOutdoors),
        const MapStyleSelection.style(kStyleIdOutdoors),
      );
    });

    test('auto differs from an explicit style', () {
      expect(
        const MapStyleSelection.auto(),
        isNot(const MapStyleSelection.style(kStyleIdOutdoors)),
      );
    });

    test('isAuto and rawId reflect the selection', () {
      expect(const MapStyleSelection.auto().isAuto, isTrue);
      expect(const MapStyleSelection.auto().rawId, 'auto');
      expect(const MapStyleSelection.style(kStyleIdOsmBright).isAuto, isFalse);
      expect(
        const MapStyleSelection.style(kStyleIdOsmBright).rawId,
        kStyleIdOsmBright,
      );
    });
  });

  group('loadInitialMapStyle', () {
    test('returns auto when nothing is stored', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadInitialMapStyle(), const MapStyleSelection.auto());
    });

    test('returns the persisted selection for each catalog id', () async {
      for (final config in kTileStyleCatalog) {
        SharedPreferences.setMockInitialValues({kMapStyleKey: config.id});
        expect(
          await loadInitialMapStyle(),
          MapStyleSelection.style(config.id),
        );
      }
    });

    test('returns auto for the explicit "auto" sentinel', () async {
      SharedPreferences.setMockInitialValues({kMapStyleKey: 'auto'});
      expect(await loadInitialMapStyle(), const MapStyleSelection.auto());
    });

    test('falls back to auto on an unrecognised stored value', () async {
      SharedPreferences.setMockInitialValues({kMapStyleKey: 'sepia_style'});
      expect(await loadInitialMapStyle(), const MapStyleSelection.auto());
    });
  });

  group('MapStyleController.setStyle', () {
    test('writes through to SharedPreferences and updates state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      const selection = MapStyleSelection.style(kStyleIdOsmBright);
      await container
          .read(mapStyleControllerProvider.notifier)
          .setStyle(selection);

      expect(container.read(mapStyleControllerProvider), selection);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kMapStyleKey), kStyleIdOsmBright);
    });

    test('persists before mutating in-memory state', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      var stateChangeFired = false;
      container.listen<MapStyleSelection>(
        mapStyleControllerProvider,
        (_, _) => stateChangeFired = true,
      );

      final future = container
          .read(mapStyleControllerProvider.notifier)
          .setStyle(const MapStyleSelection.style(kStyleIdOutdoors));

      expect(stateChangeFired, isFalse);
      await future;

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kMapStyleKey), kStyleIdOutdoors);
      expect(stateChangeFired, isTrue);
    });

    test('round-trips auto and every catalog style', () async {
      final selections = <MapStyleSelection>[
        const MapStyleSelection.auto(),
        for (final config in kTileStyleCatalog)
          MapStyleSelection.style(config.id),
      ];

      for (final selection in selections) {
        SharedPreferences.setMockInitialValues({});
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await container
            .read(mapStyleControllerProvider.notifier)
            .setStyle(selection);

        expect(await loadInitialMapStyle(), selection);
      }
    });

    test('is a no-op when the selection is already active', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          mapStyleControllerProvider.overrideWith(
            (ref) => MapStyleController(
              const MapStyleSelection.style(kStyleIdOsmBright),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      var notified = 0;
      container.listen<MapStyleSelection>(
        mapStyleControllerProvider,
        (_, _) => notified++,
      );

      await container
          .read(mapStyleControllerProvider.notifier)
          .setStyle(const MapStyleSelection.style(kStyleIdOsmBright));

      expect(notified, 0, reason: 'no state change should be emitted');
    });
  });
}
