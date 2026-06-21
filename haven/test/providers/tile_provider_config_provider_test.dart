/// Tests for the brightness-keyed [tileProviderConfigProvider].
///
/// Verifies it resolves the current [MapStyleSelection] against the passed-in
/// brightness, so an "Auto" selection swaps light/dark with the app theme and
/// an explicit selection is brightness-independent.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/tile_provider_config_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  ProviderContainer makeContainer(MapStyleSelection selection) {
    final container = ProviderContainer(
      overrides: [
        mapStyleControllerProvider.overrideWith(
          (ref) => MapStyleController(selection),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('Auto selection', () {
    test('resolves to alidade_smooth in light', () {
      final container = makeContainer(const MapStyleSelection.auto());
      expect(
        container.read(tileProviderConfigProvider(Brightness.light)),
        same(stadiaAlidadeSmooth),
      );
    });

    test('resolves to alidade_smooth_dark in dark', () {
      final container = makeContainer(const MapStyleSelection.auto());
      expect(
        container.read(tileProviderConfigProvider(Brightness.dark)),
        same(stadiaAlidadeSmoothDark),
      );
    });
  });

  group('explicit selection', () {
    test('resolves to the chosen style for both brightnesses', () {
      final container = makeContainer(
        const MapStyleSelection.style(kStyleIdOutdoors),
      );
      expect(
        container.read(tileProviderConfigProvider(Brightness.light)),
        same(stadiaOutdoors),
      );
      expect(
        container.read(tileProviderConfigProvider(Brightness.dark)),
        same(stadiaOutdoors),
      );
    });
  });

  test('recomputes when the selection changes', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(
      container.read(tileProviderConfigProvider(Brightness.light)),
      same(stadiaAlidadeSmooth),
    );

    await container
        .read(mapStyleControllerProvider.notifier)
        .setStyle(const MapStyleSelection.style(kStyleIdOsmBright));

    // Both brightness slots of the family must re-resolve to the new (now
    // brightness-independent) style, confirming all slots invalidate together.
    expect(
      container.read(tileProviderConfigProvider(Brightness.light)),
      same(stadiaOsmBright),
    );
    expect(
      container.read(tileProviderConfigProvider(Brightness.dark)),
      same(stadiaOsmBright),
    );
  });
}
