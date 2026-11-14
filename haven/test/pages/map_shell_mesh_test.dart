// Where the Bluetooth mesh sits in the map shell, and that it is not there
// at all in a build without it (`docs/BLUETOOTH_MESH_M3_DESIGN.md` §E.1;
// `docs/BLUETOOTH_MESH_AURA_DESIGN.md` §3).
//
//  * with no radio — the flag off, or a platform without one — the shell's
//    layers, the own-location layer and the Settings page are what they were
//    before the mesh existed;
//  * the mesh button is above the map, takes a touch only on itself, and is
//    under the expanded sheet; the aura is above the sheet and under the
//    banners, and takes no touch from either.
//
// `MapShell` and `MapPage` reach the Rust bridge and cannot be pumped
// (CLAUDE.md): the layering is pumped through `MapShell.buildLayers`, and
// the three places that decide whether the mesh is on screen are pinned from
// the source.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/background_location_provider.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/map/mesh_aura_overlay.dart';
import 'package:haven/src/widgets/map/mesh_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mesh_ui_harness.dart';

const Size _phone = Size(390, 844);

const _map = SizedBox(key: ValueKey('map'));
const _dim = SizedBox(key: ValueKey('dim'));
const _invitations = SizedBox(key: ValueKey('invitations'));
const _settings = SizedBox(key: ValueKey('settings'));
const _banners = SizedBox(key: ValueKey('banners'));
const _sheet = SizedBox(key: ValueKey('sheet'));
const _button = SizedBox(key: ValueKey('mesh-button'));
const _aura = SizedBox(key: ValueKey('mesh-aura'));

/// What each layer wraps, bottom-most first.
List<Key?> _order(List<Widget> layers) => [
  for (final layer in layers)
    switch (layer) {
      Positioned(:final child) => child.key,
      PositionedDirectional(:final child) => switch (child) {
        Align(:final child) => child!.key,
        _ => child.key,
      },
      _ => layer.key,
    },
];

/// `lib/` source with whole-line comments dropped and whitespace folded.
String _source(String path) => File(path)
    .readAsLinesSync()
    .where((line) => !line.trimLeft().startsWith('//'))
    .join(' ')
    .replaceAll(RegExp(r'\s+'), ' ');

void main() {
  group('with no radio', () {
    test('the build flag is off unless a build asks for it, and then there '
        'is no radio on any platform', () {
      expect(meshEnabled, isFalse);
      for (final android in [true, false]) {
        final container = ProviderContainer(
          overrides: [platformIsAndroidProvider.overrideWithValue(android)],
        );
        addTearDown(container.dispose);

        expect(container.read(meshAvailableProvider), isFalse);
      }
    });

    test('with the flag on, only Android has one, and nothing of the mesh '
        'is on screen for a radio that cannot be asked', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      for (final android in [true, false]) {
        final container = ProviderContainer(
          overrides: [
            meshEnabledProvider.overrideWithValue(true),
            platformIsAndroidProvider.overrideWithValue(android),
          ],
        );
        addTearDown(container.dispose);

        expect(container.read(meshRadioProvider) != null, android);
        // No native end answers here: the question fails, and that is "no".
        expect(await container.read(meshSupportedProvider.future), isFalse);
        expect(container.read(meshAvailableProvider), isFalse);
      }
    });

    test("the shell's layers are the six they were", () {
      final layers = MapShell.buildLayers(
        topPadding: 47,
        bottomPadding: 34,
        map: _map,
        dimOverlay: _dim,
        invitationsButton: _invitations,
        settingsButton: _settings,
        statusBanners: _banners,
        circlesSheet: _sheet,
      );

      expect(_order(layers), [
        _map.key,
        _dim.key,
        _invitations.key,
        _settings.key,
        _sheet.key,
        _banners.key,
      ]);
      expect(layers.map((layer) => layer.runtimeType), [
        SizedBox,
        Positioned,
        PositionedDirectional,
        PositionedDirectional,
        SizedBox,
        PositionedDirectional,
      ]);
    });

    test('the shell, the map and the Settings page put the mesh on screen '
        'only where there is a radio', () {
      final shell = _source('lib/src/pages/map_shell.dart');
      expect(
        shell,
        contains('final meshOnMap = ref.watch(meshAvailableProvider);'),
      );
      expect(
        shell,
        contains(
          'meshButton: meshOnMap ? const MeshButton() : null, '
          'meshAura: meshOnMap ? const MeshAura() : null,',
        ),
      );
      expect('MeshButton('.allMatches(shell), hasLength(1));
      expect('MeshAura('.allMatches(shell), hasLength(1));

      final map = _source('lib/src/pages/map/map_page.dart');
      expect(
        map,
        contains(
          'if (ref.watch(meshAvailableProvider)) '
          'OwnLocationLayer( point: _currentLatLng, '
          'darkBasemap: tileConfig.id == kStyleIdAlidadeSmoothDark, ) else '
          'MarkerLayer(markers: [ownLocationMarker(_currentLatLng)]),',
        ),
      );
      expect('OwnLocationLayer('.allMatches(map), hasLength(1));

      final settings = _source('lib/src/pages/settings/settings_page.dart');
      expect(
        settings,
        contains(
          'if (ref.watch(meshAvailableProvider)) HavenSettingsTile( '
          'icon: LucideIcons.bluetooth,',
        ),
      );
      expect('showMeshStatsSheet('.allMatches(settings), hasLength(1));
    });

    test('at a resume the shell reads what the map shows of the mesh '
        'against the clock again', () {
      final shell = _source('lib/src/pages/map_shell.dart');

      expect(
        shell,
        contains(
          'unawaited(ref.read(meshProvider.notifier).reconcile()); '
          'ref.invalidate(meshPhaseProvider);',
        ),
      );
    });
  });

  group('with a radio', () {
    test('the button is above the map and under the dim overlay; the aura '
        'above the sheet and under the banners', () {
      final layers = MapShell.buildLayers(
        topPadding: 47,
        bottomPadding: 34,
        map: _map,
        dimOverlay: _dim,
        invitationsButton: _invitations,
        settingsButton: _settings,
        statusBanners: _banners,
        circlesSheet: _sheet,
        meshButton: _button,
        meshAura: _aura,
      );

      expect(_order(layers), [
        _map.key,
        _button.key,
        _dim.key,
        _invitations.key,
        _settings.key,
        _sheet.key,
        _aura.key,
        _banners.key,
      ]);
    });

    /// The real layer stack round the real mesh button and aura, with a
    /// stand-in for the map, the sheet at [sheet] of the height, and a
    /// banner with one remedy.
    Future<({MeshHarness mesh, List<String> taps})> pumpShell(
      WidgetTester tester, {
      required double sheet,
      bool on = false,
    }) async {
      SharedPreferences.setMockInitialValues({kMeshIntroSeenKey: true});
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = _phone;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final mesh = MeshHarness();
      if (on) mesh.on();
      final taps = <String>[];
      Widget tappable(String name) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => taps.add(name),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: mesh.overrides,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: MapShell.buildLayers(
                  topPadding: 47,
                  bottomPadding: 34,
                  map: Positioned.fill(child: tappable('map')),
                  dimOverlay: DimOverlay(opacity: sheet > 0.5 ? 1 : 0),
                  invitationsButton: const SizedBox(),
                  settingsButton: const SizedBox(),
                  statusBanners: SizedBox(
                    width: 300,
                    height: 60,
                    child: tappable('remedy'),
                  ),
                  circlesSheet: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: sheet,
                      widthFactor: 1,
                      child: tappable('sheet'),
                    ),
                  ),
                  meshButton: const MeshButton(),
                  meshAura: const MeshAura(),
                ),
              ),
            ),
          ),
        ),
      );
      await settleMesh(tester);
      mesh.journal.clear();
      return (mesh: mesh, taps: taps);
    }

    final button = meshButtonRect(_phone, EdgeInsets.zero).center;

    testWidgets('over the collapsed sheet a tap beside the button is the '
        "map's, and a tap on it is the button's — whatever the map page has "
        'spread over itself', (tester) async {
      // The stand-in for the map takes every touch that reaches it, as the
      // map page's own loading scrim and its error overlay do. The button is
      // the shell's, like the two buttons at the top, and stays above them:
      // turning mesh on needs neither tiles nor a fix.
      final t = await pumpShell(tester, sheet: 0.12);

      await tester.tapAt(button + const Offset(60, -200));
      expect(t.taps, ['map']);

      await tester.tapAt(button);
      await tester.pumpAndSettle();
      expect(t.mesh.journal, contains('mesh.start'));
      expect(t.taps, ['map']);
    });

    testWidgets('the expanded sheet covers the button', (tester) async {
      final t = await pumpShell(tester, sheet: 0.85);

      await tester.tapAt(button);
      await tester.pumpAndSettle();

      expect(t.taps, ['sheet']);
      expect(t.mesh.journal, isEmpty);
    });

    testWidgets('under the running aura the banner, the sheet and the map '
        'each still take their taps', (tester) async {
      final t = await pumpShell(tester, sheet: 0.3, on: true);
      expect(find.byType(MeshAuraOverlay), findsOneWidget);

      // Inside the hue: on the banner where it nears the left edge, at the
      // left edge of the map, and at the bottom edge of the sheet.
      await tester.tapAt(const Offset(20, 47 + 64 + 4));
      await tester.tapAt(const Offset(2, 300));
      await tester.tapAt(const Offset(195, 842));

      expect(t.taps, ['remedy', 'map', 'sheet']);
    });
  });
}
