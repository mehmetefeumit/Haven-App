/// The map-style page's previews are bundled with the app, one per style and
/// scene, and the generator that renders them cannot drift from the page.
///
/// The bundled-asset test reads the test build's asset manifest, which lists
/// exactly the files pubspec.yaml declares that exist on disk, so it fails
/// both for an image missing from disk and for one the app would not ship. It
/// stays red until `scripts/generate_map_style_previews.sh` has been run and
/// its output committed.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:haven/src/pages/settings/map_style_settings_page.dart';

const String _generatorPath = '../scripts/generate_map_style_previews.sh';
const String _previewDir = 'assets/map_style_previews';

String _generator() => File(_generatorPath).readAsStringSync();

/// The words of the generator's bash array `name=( ... )`, one per line.
List<String> _bashArray(String name) {
  final body = RegExp(
    '^$name=\\(\\n(.*?)^\\)',
    multiLine: true,
    dotAll: true,
  ).firstMatch(_generator());
  expect(body, isNotNull, reason: 'no $name=( ... ) array in the generator');
  return [
    for (final line in body!.group(1)!.split('\n'))
      if (line.trim().isNotEmpty) line.trim().replaceAll('"', ''),
  ];
}

int _bashInt(String name) {
  final match = RegExp(
    '^$name=([0-9]+)\$',
    multiLine: true,
  ).firstMatch(_generator());
  expect(match, isNotNull, reason: 'no $name=<int> in the generator');
  return int.parse(match!.group(1)!);
}

/// Every image the page can show: whatever each offered selection resolves
/// to, plus every catalog config, since a persisted selection may pin any of
/// them and `MapStyleSelection.resolve` only ever returns a catalog config.
Set<String> _everyShowableAsset() => {
  for (final scene in MapStylePreviewScene.values) ...[
    for (final selection in selectableMapStyles)
      for (final brightness in Brightness.values)
        mapStylePreviewAsset(selection.resolve(brightness), scene),
    for (final config in kTileStyleCatalog) mapStylePreviewAsset(config, scene),
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('generator', () {
    test('renders every catalog style', () {
      expect(_bashArray('STYLES'), [
        for (final config in kTileStyleCatalog) config.id,
      ]);
    });

    test('renders every scene the page shows, and no other', () {
      expect(
        [for (final entry in _bashArray('SCENES')) entry.split(' ').first],
        [for (final scene in MapStylePreviewScene.values) scene.name],
      );
    });

    test('renders at the preview box height', () {
      // At another height the box would scale the image, labels included.
      expect(_bashInt('LOGICAL_HEIGHT'), kMapStylePreviewHeight);
    });
  });

  test(
    'every preview the page can show is bundled, at the rendered size',
    () async {
      final width = _bashInt('LOGICAL_WIDTH') * _bashInt('RENDER_SCALE');
      final height = _bashInt('LOGICAL_HEIGHT') * _bashInt('RENDER_SCALE');
      final bundled = (await AssetManifest.loadFromAssetBundle(
        rootBundle,
      )).listAssets().toSet();
      expect(
        _everyShowableAsset().difference(bundled),
        isEmpty,
        reason:
            'not bundled (declared in pubspec.yaml and on disk): run '
            'scripts/generate_map_style_previews.sh and commit its output',
      );
      for (final asset in _everyShowableAsset()) {
        final data = await rootBundle.load(asset);
        final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
        final frame = await codec.getNextFrame();
        expect(
          (frame.image.width, frame.image.height),
          (width, height),
          reason: asset,
        );
        frame.image.dispose();
        codec.dispose();
      }
    },
  );

  test('the preview directory holds nothing the page cannot show', () {
    // Every file in a declared asset directory ships in the app.
    final stray = [
      for (final file in Directory(_previewDir).listSync().whereType<File>())
        if (!file.uri.pathSegments.last.startsWith('.'))
          '$_previewDir/${file.uri.pathSegments.last}',
    ].where((asset) => !_everyShowableAsset().contains(asset));
    expect(stray, isEmpty);
  });
}
