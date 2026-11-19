// A layer of the map shell that comes or goes takes nothing from the layers
// that stay.
//
// The shell's list of layers changes length at run time: the Bluetooth mesh's
// button and aura arrive when the radio answers that this phone can run the
// mesh, and leave when a start answers that it cannot. A `Stack` handed a
// list of another length keeps, between the two ends that still line up, only
// its keyed children. The circles sheet was not keyed: it was built again
// from nothing, and the new sheet attached itself to the shell's one
// `DraggableScrollableController` before the old one had let go of it — an
// assertion in a debug build (CI run 44486540042, the mesh lane's probe leg).
// With assertions compiled out, by the framework's source, the old sheet's
// dispose then detaches the controller from the new sheet and disposes the
// new sheet's extent. No release build runs here: what stands in for one is
// that the sheet's State is never a second one, and that the controller and
// a drag each move the sheet that is on screen after the layers change.
//
// `MapShell` and `MapPage` reach the Rust bridge and cannot be pumped
// (CLAUDE.md): the layers are pumped through `MapShell.buildLayers` over the
// REAL sheet, dim overlay, mesh button and aura, round one controller, and
// the three keys the shell itself hands over are pinned from the source.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:haven/src/widgets/common/dim_overlay.dart';
import 'package:haven/src/widgets/map/mesh_aura_overlay.dart';
import 'package:haven/src/widgets/map/mesh_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/mesh_ui_harness.dart';
import '../mocks/mock_circle_service.dart';

const Size _phone = Size(390, 844);

/// A layer that is nothing but a `State`, standing in for one that cannot be
/// pumped or whose own content is no part of what is read here.
class _Layer extends StatefulWidget {
  const _Layer(this.name, {super.key});

  final String name;

  @override
  State<_Layer> createState() => _LayerState();
}

class _LayerState extends State<_Layer> {
  @override
  Widget build(BuildContext context) => const SizedBox.square(dimension: 48);
}

/// The `State` of every stand-in on screen, by its name.
Map<String, State> _standIns(WidgetTester tester) => {
  for (final state in tester.stateList<_LayerState>(find.byType(_Layer)))
    state.widget.name: state,
};

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({kMeshIntroSeenKey: true});
  });

  void phone(WidgetTester tester) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = _phone;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('whichever of the three optional layers come and go, every '
      'layer that stays keeps its State', (tester) async {
    phone(tester);
    const shapes = [
      (button: false, aura: false, debug: false),
      (button: true, aura: false, debug: false),
      (button: false, aura: true, debug: false),
      (button: false, aura: false, debug: true),
      (button: true, aura: true, debug: false),
      (button: true, aura: false, debug: true),
      (button: false, aura: true, debug: true),
      (button: true, aura: true, debug: true),
    ];
    List<Widget> layers(({bool button, bool aura, bool debug}) shape) =>
        MapShell.buildLayers(
          topPadding: 47,
          bottomPadding: 34,
          map: const _Layer('map', key: MapShell.mapLayerKey),
          dimOverlay: const _Layer('dim'),
          invitationsButton: const _Layer('invitations'),
          settingsButton: const _Layer('settings'),
          statusBanners: const _Layer('banners'),
          circlesSheet: const _Layer('sheet', key: MapShell.sheetLayerKey),
          meshButton: shape.button ? const _Layer('mesh button') : null,
          meshAura: shape.aura ? const _Layer('mesh aura') : null,
          debugOverlay: shape.debug
              ? const _Layer('debug', key: MapShell.debugLayerKey)
              : null,
        );
    Future<void> pump(({bool button, bool aura, bool debug}) shape) =>
        tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(children: layers(shape)),
          ),
        );

    for (final from in shapes) {
      // A layer that today always lines up with an end of the list — the
      // mesh button, straight after the map — is keyed like the rest.
      expect(layers(from).map((layer) => layer.key), everyElement(isNotNull));
      for (final to in shapes) {
        await pump(from);
        final before = _standIns(tester);
        await pump(to);
        final after = _standIns(tester);

        expect(tester.takeException(), isNull, reason: '$from -> $to');
        expect(after.keys, [
          'map',
          if (to.button) 'mesh button',
          'dim',
          'invitations',
          'settings',
          'sheet',
          if (to.aura) 'mesh aura',
          'banners',
          if (to.debug) 'debug',
        ], reason: '$from -> $to');
        for (final name in before.keys.where(after.containsKey)) {
          expect(
            after[name],
            same(before[name]),
            reason: '$name, $from -> $to',
          );
        }
      }
    }
  });

  group('round the real sheet and its one controller', () {
    /// The shell's layers as `_MapShellState.build` composes them — the mesh
    /// layers only where [meshAvailableProvider] reads true, one sheet
    /// controller for the life of the shell — before the radio has answered
    /// whether this phone can run the mesh. `answer` is the radio answering
    /// that it can.
    Future<
      ({
        DraggableScrollableController sheet,
        void Function() answer,
        ProviderContainer container,
      })
    >
    pumpShell(WidgetTester tester) async {
      phone(tester);
      final mesh = MeshHarness();
      final asked = Completer<void>();
      mesh.radio.held['supported'] = asked.future;
      final sheet = DraggableScrollableController();
      addTearDown(sheet.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...mesh.overrides,
            circleServiceProvider.overrideWithValue(MockCircleService()),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final meshOnMap = ref.watch(meshAvailableProvider);
                  return Stack(
                    children: MapShell.buildLayers(
                      topPadding: 47,
                      bottomPadding: 34,
                      map: const _Layer('map', key: MapShell.mapLayerKey),
                      dimOverlay: const DimOverlay(opacity: 0),
                      invitationsButton: const _Layer('invitations'),
                      settingsButton: const _Layer('settings'),
                      statusBanners: const _Layer('banners'),
                      circlesSheet: CirclesBottomSheet(
                        key: MapShell.sheetLayerKey,
                        controller: sheet,
                        onExpansionChanged: (_) {},
                      ),
                      meshButton: meshOnMap ? const MeshButton() : null,
                      meshAura: meshOnMap ? const MeshAura() : null,
                      debugOverlay: const _Layer(
                        'debug',
                        key: MapShell.debugLayerKey,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await settleMesh(tester);
      expect(find.byType(MeshButton), findsNothing);
      expect(find.byType(MeshAura), findsNothing);

      return (
        sheet: sheet,
        answer: asked.complete,
        container: ProviderScope.containerOf(
          tester.element(find.byType(CirclesBottomSheet)),
        ),
      );
    }

    /// Every `State` a layer that is always there holds.
    Map<String, State> states(WidgetTester tester) => {
      ..._standIns(tester),
      'dim': tester.state(find.byType(DimOverlay)),
      'sheet': tester.state(find.byType(CirclesBottomSheet)),
      'sheet scrollable': tester.state(find.byType(DraggableScrollableSheet)),
    };

    void expectSame(Map<String, State> after, Map<String, State> before) {
      expect(after.keys, before.keys);
      for (final name in before.keys) {
        expect(after[name], same(before[name]), reason: name);
      }
    }

    /// Where the sheet's top edge is drawn.
    double sheetTop(WidgetTester tester) => tester
        .getTopLeft(
          find.descendant(
            of: find.byType(CirclesBottomSheet),
            matching: find.byType(CustomScrollView),
          ),
        )
        .dy;

    testWidgets('the mesh layers arriving, leaving and arriving again leave '
        'the sheet, the map and every other layer the State and the height '
        'they had', (tester) async {
      final t = await pumpShell(tester);
      t.sheet.jumpTo(0.55);
      await tester.pump();
      final before = states(tester);
      expect(before.keys, [
        'map',
        'invitations',
        'settings',
        'banners',
        'debug',
        'dim',
        'sheet',
        'sheet scrollable',
      ]);

      t.answer();
      await settleMesh(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MeshButton), findsOneWidget);
      expect(find.byType(MeshAura), findsOneWidget);
      expectSame(states(tester), before);
      expect(t.sheet.size, 0.55);
      expect(sheetTop(tester), moreOrLessEquals(_phone.height * 0.45));

      // A start answered that this phone cannot run the mesh.
      t.container.read(meshUnsupportedProvider.notifier).state = true;
      await settleMesh(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MeshButton), findsNothing);
      expect(find.byType(MeshAura), findsNothing);
      expectSame(states(tester), before);
      expect(t.sheet.size, 0.55);

      t.container.read(meshUnsupportedProvider.notifier).state = false;
      await settleMesh(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MeshButton), findsOneWidget);
      expectSame(states(tester), before);
      expect(t.sheet.size, 0.55);
    });

    testWidgets("after the mesh layers arrive the shell's controller still "
        'moves the sheet that is on screen', (tester) async {
      final t = await pumpShell(tester);
      t.answer();
      await settleMesh(tester);
      expect(find.byType(MeshButton), findsOneWidget);

      expect(t.sheet.isAttached, isTrue);
      t.sheet.jumpTo(0.55);
      await tester.pump();
      expect(sheetTop(tester), moreOrLessEquals(_phone.height * 0.45));

      unawaited(
        t.sheet.animateTo(
          0.85,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
        ),
      );
      await tester.pumpAndSettle();
      expect(sheetTop(tester), moreOrLessEquals(_phone.height * 0.15));
    });

    testWidgets('a drag of the sheet under way when the mesh layers arrive '
        'goes on moving it, and its release still snaps', (tester) async {
      final t = await pumpShell(tester);
      final collapsed = sheetTop(tester);

      final drag = await tester.startGesture(Offset(195, collapsed + 20));
      await drag.moveBy(const Offset(0, -40));
      await drag.moveBy(const Offset(0, -60));
      await tester.pump();
      final midDrag = sheetTop(tester);
      expect(midDrag, lessThan(collapsed - 50));

      t.answer();
      await settleMesh(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MeshButton), findsOneWidget);
      expect(sheetTop(tester), midDrag);

      await drag.moveBy(const Offset(0, -150));
      await tester.pump();
      expect(sheetTop(tester), moreOrLessEquals(midDrag - 150));

      final released = t.sheet.size;
      await drag.up();
      await tester.pumpAndSettle();
      final snap = selectSnapTargetForTesting(released, 0);
      expect(snap, isNot(released));
      expect(snap, greaterThan(kSnapSizesForTesting.first));
      expect(t.sheet.size, moreOrLessEquals(snap));
    });
  });

  test('the shell keys the three layers it hands over unwrapped', () {
    final shell = File('lib/src/pages/map_shell.dart')
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .join(' ')
        .replaceAll(RegExp(r'\s+'), ' ');

    expect(shell, contains('map: const MapPage(key: MapShell.mapLayerKey),'));
    expect(
      shell,
      contains(
        'circlesSheet: CirclesBottomSheet( key: MapShell.sheetLayerKey, '
        'controller: _sheetController,',
      ),
    );
    expect(
      shell,
      contains('? Consumer( key: MapShell.debugLayerKey, builder:'),
    );
    expect('MapPage('.allMatches(shell), hasLength(1));
    expect('CirclesBottomSheet('.allMatches(shell), hasLength(1));
  });
}
