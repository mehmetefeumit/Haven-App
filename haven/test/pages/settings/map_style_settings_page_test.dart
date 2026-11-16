/// Widget tests for [MapStyleSettingsPage] and [mapStyleLabel].
///
/// Verifies the options render, the current selection is reflected, tapping a
/// choice updates the [mapStyleControllerProvider] and persists it, the
/// previews are bundled images that switch on the frame after a tap and make
/// no network request, the map credits stay on the page, and the page never
/// uses location-privacy vocabulary (changing the basemap must not imply a
/// change to who can see the user).
///
/// The preview images are served by [_PreviewBundle], so these tests hold
/// whether or not the generated images are on disk; that they are is
/// `map_style_preview_assets_test.dart`'s promise.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/pages/settings/map_style_settings_page.dart';
import 'package:haven/src/providers/map_style_provider.dart';
import 'package:haven/src/providers/tile_cache_provider.dart';
import 'package:haven/src/providers/tile_http_client_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _previewDir = 'assets/map_style_previews/';

/// A valid 1x1 PNG, served for every preview asset.
final Uint8List _kPixelPng = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, //
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, //
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0, //
  0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00, //
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
]);

/// Serves the preview assets from memory and records which were loaded.
///
/// The asset manifest is answered in memory too, so resolving an [AssetImage]
/// completes within the test's fake-async frames.
class _PreviewBundle extends CachingAssetBundle {
  final Set<String> loaded = {};

  @override
  Future<ByteData> load(String key) async {
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(<String, Object>{})!;
    }
    if (key.startsWith(_previewDir)) {
      loaded.add(key);
      return ByteData.sublistView(_kPixelPng);
    }
    return rootBundle.load(key);
  }
}

/// Fails any attempt to open an HTTP connection, and records it.
class _NoNetworkOverrides extends HttpOverrides {
  int attempts = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    attempts++;
    throw StateError('the map-style page opened an HTTP client');
  }
}

Widget _wrap({
  MapStyleSelection initial = const MapStyleSelection.auto(),
  Brightness brightness = Brightness.light,
  _PreviewBundle? bundle,
  List<Override> overrides = const [],
}) {
  return ProviderScope(
    overrides: [
      mapStyleControllerProvider.overrideWith(
        (ref) => MapStyleController(initial),
      ),
      ...overrides,
    ],
    child: DefaultAssetBundle(
      bundle: bundle ?? _PreviewBundle(),
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const MapStyleSettingsPage(),
      ),
    ),
  );
}

/// The asset each preview on screen shows, top to bottom.
List<String> _shownPreviews(WidgetTester tester) => [
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    switch (image.image) {
      final ResizeImage resized =>
        (resized.imageProvider as AssetImage).assetName,
      final AssetImage asset => asset.assetName,
      final other => 'not a bundled asset: ${other.runtimeType}',
    },
];

List<String> _previewsOf(String configId) => [
  '$_previewDir${configId}_city.webp',
  '$_previewDir${configId}_nature.webp',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('mapStyleLabel', () {
    late AppLocalizations l10n;

    setUp(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('returns the human-readable label for each option', () {
      expect(mapStyleLabel(l10n, const MapStyleSelection.auto()), 'Minimal');
      expect(
        mapStyleLabel(l10n, const MapStyleSelection.style(kStyleIdOsmBright)),
        'Detailed',
      );
      expect(
        mapStyleLabel(l10n, const MapStyleSelection.style(kStyleIdOutdoors)),
        'Outdoors',
      );
    });

    test('falls back to Minimal for a selection not exposed as a row', () {
      expect(
        mapStyleLabel(
          l10n,
          const MapStyleSelection.style(kStyleIdAlidadeSmoothDark),
        ),
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
        find.text(
          'Calm, low-detail canvas that follows your light or dark '
          'theme',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Full-colour streets, labels, and places'),
        findsOneWidget,
      );
      expect(find.text('Shaded terrain with trails and parks'), findsOneWidget);
      expect(find.byType(RadioListTile<MapStyleSelection>), findsNWidgets(3));
    });

    testWidgets('previews are bundled images: no map, no tile fetch', (
      tester,
    ) async {
      final network = _NoNetworkOverrides();
      final previous = HttpOverrides.current;
      HttpOverrides.global = network;
      addTearDown(() => HttpOverrides.global = previous);
      var tileClientRead = false;
      var tileCacheRead = false;

      await tester.pumpWidget(
        _wrap(
          overrides: [
            tileHttpClientProvider.overrideWith((ref) {
              tileClientRead = true;
              throw StateError('tile HTTP client read');
            }),
            tileCachingProviderProvider.overrideWith((ref) {
              tileCacheRead = true;
              throw StateError('tile cache read');
            }),
          ],
        ),
      );
      await tester.pump();
      // Every style, so no style's preview reaches for the network either.
      for (final style in ['Detailed', 'Outdoors', 'Minimal']) {
        await tester.tap(find.text(style));
        await tester.pump();
        expect(
          _shownPreviews(tester),
          everyElement(startsWith(_previewDir)),
          reason: style,
        );
      }

      expect(find.byType(FlutterMap), findsNothing);
      expect(find.byType(TileLayer), findsNothing);
      expect(network.attempts, 0);
      expect(tileClientRead, isFalse);
      expect(tileCacheRead, isFalse);
    });

    testWidgets('Minimal previews the light canvas in a light theme', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap());

      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('City'), findsOneWidget);
      expect(find.text('Nature'), findsOneWidget);
      expect(_shownPreviews(tester), _previewsOf('stadia_alidade_smooth'));
    });

    testWidgets('Minimal previews the dark canvas in a dark theme', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(brightness: Brightness.dark));

      expect(_shownPreviews(tester), _previewsOf('stadia_alidade_smooth_dark'));
    });

    testWidgets('a style pinned outside the list previews what the map shows', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          initial: const MapStyleSelection.style(kStyleIdAlidadeSmoothDark),
        ),
      );

      expect(_shownPreviews(tester), _previewsOf('stadia_alidade_smooth_dark'));
    });

    testWidgets('a tapped style is previewed on the very next frame', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap());
      expect(
        find.bySemanticsLabel('Map preview (City): Minimal'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Map preview (Nature): Minimal'),
        findsOneWidget,
      );

      await tester.tap(find.text('Detailed'));
      await tester.pump();
      expect(_shownPreviews(tester), _previewsOf('stadia_osm_bright'));
      expect(
        find.bySemanticsLabel('Map preview (City): Detailed'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Map preview (Nature): Detailed'),
        findsOneWidget,
      );

      await tester.tap(find.text('Outdoors'));
      await tester.pump();
      expect(_shownPreviews(tester), _previewsOf('stadia_outdoors'));
      expect(
        find.bySemanticsLabel('Map preview (City): Outdoors'),
        findsOneWidget,
      );

      await tester.tap(find.text('Minimal'));
      await tester.pump();
      expect(_shownPreviews(tester), _previewsOf('stadia_alidade_smooth'));
      semantics.dispose();
    });

    testWidgets('opening the page loads every style it can switch to', (
      tester,
    ) async {
      for (final brightness in Brightness.values) {
        final bundle = _PreviewBundle();
        await tester.pumpWidget(_wrap(brightness: brightness, bundle: bundle));
        await tester.pump();

        expect(bundle.loaded, {
          for (final selection in selectableMapStyles)
            ..._previewsOf(selection.resolve(brightness).id),
        }, reason: '$brightness');
        // Each brightness opens with a cold image cache.
        await tester.pumpWidget(const SizedBox());
        imageCache
          ..clear()
          ..clearLiveImages();
      }
    });

    testWidgets('shows the map credits and licence link', (tester) async {
      final launched = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launched.add(
            (call.arguments as Map<Object?, Object?>)['url']! as String,
          );
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
      await tester.pumpWidget(_wrap());

      const links = {
        '© Stadia Maps': kStadiaHomeUrl,
        '© OpenMapTiles': kOpenMapTilesUrl,
        '© OpenStreetMap': kOsmCopyrightUrl,
        'Open Database License': kOsmCopyrightUrl,
      };
      for (final MapEntry(key: label, value: url) in links.entries) {
        final link = find.text(label);
        await tester.ensureVisible(link);
        await tester.pump();
        await tester.tap(link);
        await tester.pump();
        expect(launched.last, url, reason: label);
      }
      expect(launched, hasLength(links.length));
    });

    testWidgets('credit links meet the tap-target and label guidelines', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_wrap());
      await tester.ensureVisible(find.text('Open Database License'));
      await tester.pump();

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
    });

    testWidgets('marks the current selection as checked', (tester) async {
      await tester.pumpWidget(
        _wrap(initial: const MapStyleSelection.style(kStyleIdOutdoors)),
      );

      final group = tester.widget<RadioGroup<MapStyleSelection>>(
        find.byType(RadioGroup<MapStyleSelection>),
      );
      expect(group.groupValue, const MapStyleSelection.style(kStyleIdOutdoors));
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
