// The Bluetooth mesh's button on the map (`docs/BLUETOOTH_MESH_PLAN.md`
// §7.4–§7.5; `docs/BLUETOOTH_MESH_M3_DESIGN.md` §E.1–§E.2).
//
//  * a tap turns mesh on — the first time behind the disclosure, and behind
//    the phone's Bluetooth name once it can be read, with nothing stored
//    before "Turn on" — and a tap turns it off at once;
//  * a hold shows the statistics, and so do a screen reader's action and a
//    tapped notice: one sheet, however it is asked for;
//  * the state is told by icon, surface and semantics, never by colour
//    alone, and to a screen reader once;
//  * every way a turn-on can end has fixed copy, said clear of the button
//    and gone by itself unless it carries a remedy; nothing thrown is shown
//    or logged; a phone that cannot use mesh loses the button;
//  * a stop the user did not make is told beside the button until dismissed,
//    with the way back on, and to a screen reader; their own is not, and a
//    question the radio did not answer is no stop;
//  * 48 dp, in the bottom-left corner in either text direction, clear of the
//    map controls on any screen and at 200 % text.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/rust/api.dart' show MeshStartFfi;
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/mesh_aura_geometry.dart';
import 'package:haven/src/widgets/map/map_controls.dart';
import 'package:haven/src/widgets/map/mesh_button.dart';
import 'package:haven/src/widgets/mesh/mesh_intro_sheet.dart';
import 'package:haven/src/widgets/mesh/mesh_stats_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/accessibility_announcements.dart';
import '../../helpers/english_arb.dart';
import '../../helpers/fake_mesh.dart';
import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';
import '../../helpers/mesh_ui_harness.dart';

const _address = 'AA:BB:CC:DD:EE:FF';
const _name = "Ada's Pixel 9";
const Size _small = Size(320, 568);

final Finder _face = find.byKey(MeshButton.faceKey);
final Finder _notice = find.byKey(MeshButton.stoppedKey);

/// The word the button says at the bottom of the map, as drawn.
final Finder _word = find.descendant(
  of: find.byType(SnackBar),
  matching: find.byType(Material),
);

/// The disclosure, in the order it is read: three headings, each over its
/// paragraphs.
const _disclosure = [
  'meshIntroHeadingDoes',
  'meshIntroWhat',
  'meshIntroAutoOff',
  'meshIntroBattery',
  'meshIntroClosed',
  'meshIntroHeadingLearn',
  'meshIntroNearby',
  'meshIntroConnected',
  'meshIntroName',
  'meshIntroBridge',
  'meshIntroRemoved',
  'meshIntroHeadingKnow',
  'meshIntroStats',
];

Future<void> _pump(
  WidgetTester tester,
  MeshHarness mesh, {
  Size size = const Size(390, 844),
  EdgeInsets viewPadding = EdgeInsets.zero,
  Locale locale = kDefaultTestLocale,
  TextScaler textScaler = TextScaler.noScaling,
  ThemeData? theme,
  bool introSeen = true,
  bool disableAnimations = false,
}) async {
  SharedPreferences.setMockInitialValues({kMeshIntroSeenKey: introSeen});
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: mesh.overrides,
      child: MaterialApp(
        locale: locale,
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: textScaler,
            viewPadding: viewPadding,
            padding: viewPadding,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Stack(
              children: [
                // As the shell: only where the mesh is on screen.
                if (ref.watch(meshAvailableProvider))
                  const Positioned.fill(child: MeshButton()),
                // The map controls, where the map page puts them.
                Positioned(
                  right: HavenSpacing.base,
                  bottom: size.height * 0.12 + HavenSpacing.base,
                  child: const MapControls(),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await settleMesh(tester);
  mesh.journal.clear();
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(MapControls)));

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MapControls)));

Material _surface(WidgetTester tester) => tester.widget<Material>(
  find.descendant(of: _face, matching: find.byType(Material)),
);

Icon _icon(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(of: _face, matching: find.byType(Icon)).first,
);

/// Whether the button shows mesh as on: the filled surface.
bool _shownOn(WidgetTester tester) =>
    _surface(tester).color == HavenMeshColors.active;

double _contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  group('the state is told', () {
    testWidgets('to a screen reader once: the name, the toggle, and what '
        'else is true as the value; with the hints and the hold', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      for (final (state, linked, toggled, value, hint) in [
        (MeshRadioState.stopped, false, false, '', 'turn on'),
        (MeshRadioState.running, false, true, '', 'turn off'),
        (
          MeshRadioState.running,
          true,
          true,
          'connected to a nearby phone',
          'turn off',
        ),
        (
          MeshRadioState.paused,
          false,
          true,
          'paused, Bluetooth is off',
          'turn off',
        ),
      ]) {
        final mesh = MeshHarness();
        if (state != MeshRadioState.stopped) {
          mesh.on(linked: linked, state: state);
        }
        await _pump(tester, mesh);

        expect(
          tester.getSemantics(_face),
          matchesSemantics(
            label: 'Bluetooth mesh',
            value: value,
            isButton: true,
            hasToggledState: true,
            isToggled: toggled,
            hasTapAction: true,
            hasLongPressAction: true,
            onTapHint: hint,
            onLongPressHint: 'show mesh activity',
            customActions: const [
              CustomSemanticsAction(label: 'Mesh activity'),
            ],
          ),
          reason: '$state linked: $linked',
        );
        await tester.pumpWidget(const SizedBox());
      }
      handle.dispose();
    });

    testWidgets('by the right icon: plain while Bluetooth is on, struck '
        'through only while it is off, where the button keeps a blue edge', (
      tester,
    ) async {
      for (final (state, linked, icon) in [
        (MeshRadioState.stopped, false, LucideIcons.bluetooth),
        (MeshRadioState.running, false, LucideIcons.bluetooth),
        (MeshRadioState.running, true, LucideIcons.bluetoothConnected),
        (MeshRadioState.paused, false, LucideIcons.bluetoothOff),
      ]) {
        final mesh = MeshHarness();
        if (state != MeshRadioState.stopped) {
          mesh.on(linked: linked, state: state);
        }
        await _pump(tester, mesh);

        expect(_icon(tester).icon, icon, reason: '$state linked: $linked');
        expect(
          find.byKey(MeshButton.linkedKey),
          linked ? findsOneWidget : findsNothing,
        );
        expect(
          find.descendant(of: _face, matching: find.byIcon(LucideIcons.pause)),
          state == MeshRadioState.paused ? findsOneWidget : findsNothing,
        );
        // Paused is still on: its edge is the blue of the filled button.
        final side = (_surface(tester).shape! as RoundedRectangleBorder).side;
        expect(
          side.color == HavenMeshColors.active && side.width == 2,
          state == MeshRadioState.paused,
          reason: '$state',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('without colour: each state has its own icon, mark or '
        'surface, and on is a surface that stands apart from off in either '
        'theme', (tester) async {
      for (final theme in [HavenTheme.light(), HavenTheme.dark()]) {
        final looks = <String>{};
        final surfaces = <MeshRadioState, Color>{};
        for (final (state, linked) in [
          (MeshRadioState.stopped, false),
          (MeshRadioState.running, false),
          (MeshRadioState.running, true),
          (MeshRadioState.paused, false),
        ]) {
          final mesh = MeshHarness();
          if (state != MeshRadioState.stopped) {
            mesh.on(linked: linked, state: state);
          }
          await _pump(tester, mesh, theme: theme);
          final surface = _surface(tester);
          final side = (surface.shape! as RoundedRectangleBorder).side;
          final marks = find
              .descendant(of: _face, matching: find.byType(Icon))
              .evaluate()
              .length;
          surfaces[state] = surface.color!;

          // What is left of the look with every hue taken out of it.
          looks.add(
            '${_icon(tester).icon!.codePoint} marks:$marks '
            'dot:${find.byKey(MeshButton.linkedKey).evaluate().length} '
            'tone:${(surface.color!.computeLuminance() * 10).round()} '
            'outline:${side.width}',
          );
          await tester.pumpWidget(const SizedBox());
        }

        expect(looks, hasLength(4), reason: '${theme.brightness}');
        // Off and on share an icon: the fill is what tells them apart.
        expect(
          _contrast(
            surfaces[MeshRadioState.running]!,
            surfaces[MeshRadioState.stopped]!,
          ),
          greaterThanOrEqualTo(3),
          reason: '${theme.brightness}',
        );
      }
    });

    testWidgets('legibly in the light and the dark theme', (tester) async {
      for (final theme in [HavenTheme.light(), HavenTheme.dark()]) {
        for (final state in MeshRadioState.values) {
          final mesh = MeshHarness();
          if (state != MeshRadioState.stopped) mesh.on(state: state);
          await _pump(tester, mesh, theme: theme);

          expect(
            _contrast(_icon(tester).color!, _surface(tester).color!),
            greaterThanOrEqualTo(4.5),
            reason: '${theme.brightness} $state',
          );
          await tester.pumpWidget(const SizedBox());
        }
      }
    });

    testWidgets('with no tooltip: a tooltip would take the hold', (
      tester,
    ) async {
      await _pump(tester, MeshHarness());

      expect(
        find.descendant(
          of: find.byType(MeshButton),
          matching: find.byType(Tooltip),
        ),
        findsNothing,
      );
    });
  });

  group('the button is', () {
    testWidgets('a 48 dp target in the bottom-left corner, the same in a '
        'right-to-left language', (tester) async {
      for (final locale in const [Locale('en'), Locale('ar')]) {
        await _pump(tester, MeshHarness(), locale: locale);

        expect(
          tester.getRect(_face),
          meshButtonRect(const Size(390, 844), EdgeInsets.zero),
          reason: '$locale',
        );
        expect(tester.getSize(_face), const Size(48, 48));
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('clear of the map controls, and its notice with it: in '
        'Arabic, at 200 % text, on a small phone, and in landscape beside a '
        'sensor housing', (tester) async {
      for (final (size, viewPadding, locale, scale) in [
        (const Size(390, 844), EdgeInsets.zero, const Locale('ar'), 1.0),
        (const Size(390, 844), EdgeInsets.zero, const Locale('en'), 2.0),
        (_small, EdgeInsets.zero, const Locale('en'), 2.0),
        (
          const Size(852, 393),
          const EdgeInsets.only(left: 59, right: 59),
          const Locale('en'),
          1.0,
        ),
      ]) {
        final mesh = MeshHarness();
        await _pump(
          tester,
          mesh,
          size: size,
          viewPadding: viewPadding,
          locale: locale,
          textScaler: TextScaler.linear(scale),
        );
        _container(tester).read(meshStoppedNoticeProvider.notifier).state =
            true;
        await tester.pump();
        final row = '$size $locale x$scale';
        final l10n = _l10n(tester);
        final screen = Offset.zero & size;
        final controls = tester.getRect(find.byType(MapControls));
        final button = tester.getRect(_face);
        final notice = tester.getRect(_notice);

        expect(tester.takeException(), isNull, reason: row);
        expect(button.overlaps(controls), isFalse, reason: row);
        expect(notice.overlaps(controls), isFalse, reason: row);
        expect(notice.overlaps(button), isFalse, reason: row);
        expect(
          button.left,
          greaterThanOrEqualTo(viewPadding.left),
          reason: row,
        );
        expect(screen.contains(notice.topLeft), isTrue, reason: row);
        expect(screen.contains(notice.bottomRight), isTrue, reason: row);
        // The notice's words, its way back on and its way out are within
        // reach.
        expect(find.text(l10n.meshStoppedNotice), findsOneWidget);
        for (final action in [l10n.meshTurnOn, l10n.meshStoppedOk]) {
          await tester.ensureVisible(find.text(action));
          expect(
            screen.contains(tester.getCenter(find.text(action))),
            isTrue,
            reason: '$row $action',
          );
        }
        await tester.tap(find.text(l10n.meshStoppedOk));
        await tester.pump();
        expect(_notice, findsNothing, reason: row);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('the first tap', () {
    testWidgets('shows every paragraph of the disclosure, in order, and '
        'nothing starts before "Turn on"', (tester) async {
      final handle = tester.ensureSemantics();
      final mesh = MeshHarness();
      await _pump(tester, mesh, introSeen: false);

      await tester.tap(_face);
      await tester.pumpAndSettle();

      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byType(MeshIntroSheet),
              matching: find.byType(Text),
            ),
          )
          .map((text) => text.data)
          .toList();
      final read = [for (final key in _disclosure) englishArb(key)];
      expect(
        texts.where(read.contains).toList(),
        read,
        reason: 'T-BRIDGE-12: meshIntroBridge is among them',
      );
      // Each is a node of its own for a screen reader to step through, and
      // the three headings are headings to it.
      for (final key in _disclosure) {
        final node = tester
            .getSemantics(find.text(englishArb(key)))
            .getSemanticsData();
        expect(node.label, englishArb(key));
        expect(
          node.flagsCollection.isHeader,
          key.startsWith('meshIntroHeading'),
          reason: key,
        );
      }
      // The radio is asked for the name to show, and for nothing else.
      expect(mesh.journal.toSet().difference({'radio.bluetoothName'}), isEmpty);

      await tester.tap(find.text(_l10n(tester).commonCancel));
      await tester.pumpAndSettle();

      expect(mesh.journal.toSet().difference({'radio.bluetoothName'}), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kMeshIntroSeenKey), isFalse);
      // So it is shown again.
      await tester.tap(_face);
      await tester.pumpAndSettle();
      expect(find.byType(MeshIntroSheet), findsOneWidget);
      handle.dispose();
    });

    testWidgets("shows the phone's Bluetooth name once it can be read, "
        'before anything is stored; backing out stores nothing', (
      tester,
    ) async {
      final mesh = MeshHarness()..radio.bluetoothNameAnswer = _name;
      await _pump(tester, mesh, introSeen: false);
      await tester.tap(_face);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_l10n(tester).meshTurnOn));
      await tester.pumpAndSettle();

      // The permission is held, and the name is on screen with the way to
      // change it; the engine has not been asked for anything.
      expect(mesh.journal, contains('radio.requestPermission'));
      expect(find.text('\u2068$_name\u2069'), findsOneWidget);
      expect(find.text(_l10n(tester).meshNameStepTitle), findsOneWidget);
      expect(find.text(_l10n(tester).meshIntroName), findsOneWidget);
      expect(find.text(_l10n(tester).meshNameStepChange), findsOneWidget);
      expect(find.text(_l10n(tester).meshBluetoothSettings), findsOneWidget);
      expect(mesh.journal.where((call) => call.startsWith('mesh.')), isEmpty);
      // No mark of a start under way while the user is the one answering.
      expect(find.byKey(MeshButton.startingKey), findsNothing);

      await tester.tap(find.text(_l10n(tester).commonCancel));
      await tester.pumpAndSettle();
      await settleMesh(tester);

      expect(mesh.journal, isNot(contains('mesh.start')));
      expect(mesh.journal, isNot(contains('radio.start')));
      expect(find.byType(SnackBar), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kMeshIntroSeenKey), isFalse);
      // Nothing holds the name once its step has closed.
      expect(find.textContaining(_name), findsNothing);
      expect(
        '${_container(tester).read(meshProvider)}',
        isNot(contains(_name)),
      );
    });

    testWidgets('the name step leads with the name: on a small phone at '
        '200 % text it is in view without scrolling', (tester) async {
      const name = "Ada's Galaxy Z Fold6";
      await loadAppFont();
      final mesh = MeshHarness()..radio.bluetoothNameAnswer = name;
      await _pump(
        tester,
        mesh,
        size: _small,
        textScaler: const TextScaler.linear(2),
        theme: HavenTheme.light(),
        introSeen: false,
      );
      await tester.tap(_face);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_l10n(tester).meshTurnOn));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final shown = find.text('\u2068$name\u2069');
      final rect = tester.getRect(shown);
      expect((Offset.zero & _small).contains(rect.topLeft), isTrue);
      expect((Offset.zero & _small).contains(rect.bottomRight), isTrue);
      // Whole, and not under the dialog's buttons: its first line and its
      // last can both be touched.
      final text = tester.renderObject(shown);
      for (final at in [
        rect.topLeft + const Offset(2, 2),
        rect.bottomLeft + const Offset(2, -2),
      ]) {
        expect(
          tester.hitTestOnBinding(at).path.map((entry) => entry.target),
          contains(text),
        );
      }
      // And it comes before the sentence about it.
      final sentence = find.text(_l10n(tester).meshIntroName);
      expect(rect.bottom, lessThanOrEqualTo(tester.getRect(sentence).top));
    });

    testWidgets('goes on, behind the name, to turn mesh on: the engine, then '
        'the radio, said once as a start, and the disclosure is not shown '
        'again', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..radio.bluetoothNameAnswer = _name;
      await _pump(tester, mesh, introSeen: false);
      await tester.tap(_face);
      await tester.pumpAndSettle();
      await tester.tap(find.text(_l10n(tester).meshTurnOn));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_l10n(tester).meshTurnOn));
      await tester.pumpAndSettle();

      expect(
        mesh.journal,
        containsAllInOrder([
          'radio.requestPermission',
          'radio.bluetoothName',
          'radio.bluetoothOn',
          'mesh.start',
          'radio.start',
        ]),
      );
      expect(_shownOn(tester), isTrue);
      expect(find.text(_l10n(tester).meshTurnedOn), findsOneWidget);
      // One start, though its mark left for the name step and came back.
      expect(announced, [_l10n(tester).meshTurningOn]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(kMeshIntroSeenKey), isTrue);

      // Off and on again: straight on.
      await tester.tap(_face);
      await tester.pumpAndSettle();
      mesh.journal.clear();
      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(find.byType(MeshIntroSheet), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(mesh.journal, isNot(contains('radio.bluetoothName')));
      expect(mesh.journal, contains('radio.start'));
    });

    testWidgets('with a name that cannot be read has the general sentence '
        'alone, and no step of its own', (tester) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh, introSeen: false);
      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(find.text(_l10n(tester).meshIntroName), findsOneWidget);
      expect(find.textContaining('Bluetooth name is'), findsNothing);

      await tester.tap(find.text(_l10n(tester).meshTurnOn));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(mesh.journal, contains('radio.start'));
    });
  });

  group('a tap', () {
    testWidgets('turns mesh on and says so, with where the statistics are '
        'and an Undo that turns it off', (tester) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh);

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(mesh.journal, containsAllInOrder(['mesh.start', 'radio.start']));
      expect(_shownOn(tester), isTrue);
      expect(
        find.text(
          'Bluetooth mesh is on. Press and hold the button to see activity.',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text(_l10n(tester).meshUndo));
      await tester.pumpAndSettle();

      expect(mesh.journal, containsAllInOrder(['radio.stop', 'mesh.stop']));
      expect(_shownOn(tester), isFalse);
    });

    testWidgets('the word that mesh is on goes by itself, and holds no later '
        'word back', (tester) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh);
      await tester.tap(_face);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);

      // Long enough to be read at large text, with its Undo.
      await tester.pump(kMeshSaid - const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      // Anybody's next word is shown.
      ScaffoldMessenger.of(
        tester.element(find.byType(MapControls)),
      ).showSnackBar(const SnackBar(content: Text('another')));
      await tester.pumpAndSettle();
      expect(find.text('another'), findsOneWidget);
    });

    testWidgets('the word is said clear of the button and of the map '
        'controls, at 200 % text too, and the button under it still takes '
        'its tap', (tester) async {
      for (final (scale, viewPadding) in [
        (1.0, EdgeInsets.zero),
        (2.0, EdgeInsets.zero),
        // Between a sensor housing and a gesture bar there is least room.
        (2.0, const EdgeInsets.only(top: 47, bottom: 34)),
      ]) {
        final mesh = MeshHarness();
        await _pump(
          tester,
          mesh,
          size: _small,
          viewPadding: viewPadding,
          textScaler: TextScaler.linear(scale),
        );
        await tester.tap(_face);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'x$scale');
        final word = tester.getRect(_word.first);
        expect(find.text(_l10n(tester).meshTurnedOn), findsOneWidget);
        expect(word.overlaps(tester.getRect(_face)), isFalse, reason: '$scale');
        expect(
          word.overlaps(tester.getRect(find.byType(MapControls))),
          isFalse,
          reason: 'x$scale',
        );
        expect((Offset.zero & _small).contains(word.topLeft), isTrue);
        expect((Offset.zero & _small).contains(word.bottomRight), isTrue);
        expect(word.top, greaterThanOrEqualTo(viewPadding.top));

        mesh.journal.clear();
        await tester.tap(_face);
        await tester.pumpAndSettle();
        expect(mesh.journal, contains('mesh.stop'), reason: 'x$scale');
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('turns mesh off at once: no question, no notice, nothing '
        'announced', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(mesh.journal, containsAllInOrder(['radio.stop', 'mesh.stop']));
      expect(_shownOn(tester), isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(_notice, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(announced, isEmpty);
    });

    testWidgets('that could not turn mesh off says so, and a stop that comes '
        "later is told as not the user's", (tester) async {
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);
      mesh.mesh.throws['stop'] = StateError('group $_address');
      mesh.radio.throws['stop'] = StateError(_address);

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(find.text(_l10n(tester).meshErrorStopFailed), findsOneWidget);
      expect(find.textContaining(_address), findsNothing);
      expect(_shownOn(tester), isTrue);
      expect(_notice, findsNothing);

      // Hours later the service stops by itself.
      mesh.mesh.throws.clear();
      mesh.radio.throws.clear();
      mesh.mesh.statsAnswer = meshCounts(on: false);
      mesh.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pumpAndSettle();

      expect(_shownOn(tester), isFalse);
      expect(_notice, findsOneWidget);
    });

    testWidgets('whose engine stops only at the second asking is still the '
        "user's own: no notice, nothing announced", (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);
      // The engine refuses the stop once. The turn-off's closing reconcile
      // then finds it on beside a radio that stopped, and stops it: to the
      // reconcile, a stop nobody asked for.
      mesh.mesh.throws['stop'] = StateError('group $_address');
      unawaited(
        mesh.mesh.reached('stop').then((_) => mesh.mesh.throws.clear()),
      );

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(mesh.count('mesh.stop'), 2);
      expect(_shownOn(tester), isFalse);
      expect(_notice, findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(announced, isEmpty);
      expect(_container(tester).read(meshStoppedNoticeProvider), isFalse);
    });

    testWidgets("that follows the user's own off and on again is not the "
        "user's stop: it is told", (tester) async {
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);
      await tester.tap(_face);
      await tester.pumpAndSettle();
      await tester.tap(_face);
      await tester.pumpAndSettle();
      expect(_shownOn(tester), isTrue);

      mesh.mesh.statsAnswer = meshCounts(on: false);
      mesh.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pumpAndSettle();

      expect(_shownOn(tester), isFalse);
      expect(_notice, findsOneWidget);
    });

    testWidgets('made while one is under way asks for nothing more', (
      tester,
    ) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh);

      await tester.tap(_face);
      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(mesh.count('mesh.start'), 1);
      expect(mesh.journal, isNot(contains('mesh.stop')));
    });

    testWidgets('shows a start under way on the button, says it once to a '
        'screen reader, and holds the mark still where motion is reduced', (
      tester,
    ) async {
      for (final still in [false, true]) {
        final announced = captureAccessibilityAnnouncements(tester);
        final mesh = MeshHarness();
        await _pump(tester, mesh, disableAnimations: still);
        final start = Completer<void>();
        mesh.mesh.held['start'] = start.future;

        await tester.tap(_face);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final mark = find.byKey(MeshButton.startingKey);
        expect(mark, findsOneWidget, reason: 'still: $still');
        expect(
          tester
              .widget<CircularProgressIndicator>(
                find.descendant(
                  of: mark,
                  matching: find.byType(CircularProgressIndicator),
                ),
              )
              .value,
          still ? isNotNull : isNull,
        );
        expect(announced, [_l10n(tester).meshTurningOn]);

        start.complete();
        await tester.pumpAndSettle();

        expect(mark, findsNothing);
        expect(_shownOn(tester), isTrue);
        expect(announced, [_l10n(tester).meshTurningOn]);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  testWidgets('every way a turn-on can fail has fixed copy, with its remedy '
      'where there is one, and nothing thrown is shown or logged', (
    tester,
  ) async {
    final logs = LogCapture();
    for (final (arrange, copy, remedy, opened)
        in <(void Function(MeshHarness), String, String?, String?)>[
          (
            (m) => m.radio.permissionAnswer = MeshRadioPermission.denied,
            'meshErrorNoPermission',
            null,
            null,
          ),
          (
            (m) => m.radio.permissionAnswer = MeshRadioPermission.deniedForGood,
            'meshErrorNoPermission',
            'commonOpenSettings',
            'settings.app',
          ),
          (
            (m) => m.radio.bluetoothOnAnswer = false,
            'meshErrorBluetoothOff',
            'meshBluetoothSettings',
            'radio.openBluetoothSettings',
          ),
          (
            (m) => m.radio.startAnswer = MeshRadioStart.noPermission,
            'meshErrorNoPermission',
            null,
            null,
          ),
          (
            (m) => m.radio.startAnswer = MeshRadioStart.failed,
            'meshErrorStartFailed',
            null,
            null,
          ),
          (
            (m) => m.mesh.startAnswer = MeshStartFfi.off,
            'meshErrorStartFailed',
            null,
            null,
          ),
          (
            (m) => m.mesh.throws['start'] = StateError('group $_address'),
            'meshErrorStartFailed',
            null,
            null,
          ),
          (
            (m) => m.radio.throws['requestPermission'] = StateError(_address),
            'meshErrorStartFailed',
            null,
            null,
          ),
        ]) {
      final mesh = MeshHarness();
      arrange(mesh);
      await _pump(tester, mesh);

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(find.text(englishArb(copy)), findsOneWidget, reason: copy);
      expect(find.textContaining(_address), findsNothing, reason: copy);
      expect(_shownOn(tester), isFalse, reason: copy);
      expect(_notice, findsNothing, reason: copy);
      if (remedy != null) {
        mesh.journal.clear();
        await tester.tap(find.text(englishArb(remedy)));
        await tester.pumpAndSettle();
        expect(mesh.journal, [opened], reason: copy);
      } else {
        expect(
          tester.widget<SnackBarAction>(find.byType(SnackBarAction)).label,
          // Not the app's Dismiss: under "Couldn't turn Bluetooth mesh off"
          // it is, in Hindi, Nepali and Turkish, the word for "turn off".
          _l10n(tester).meshStoppedOk,
          reason: copy,
        );
        // With nothing to be done about it, it goes by itself.
        await tester.pump(kMeshSaid);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing, reason: copy);
      }
      await tester.pumpWidget(const SizedBox());
    }
    logs.restore();

    expect(logs.joined, isNot(contains(_address)));
  });

  testWidgets("a phone that can't use mesh is told so once, and the button "
      'that could never work is gone for as long as the app runs', (
    tester,
  ) async {
    final mesh = MeshHarness()..radio.startAnswer = MeshRadioStart.unsupported;
    await _pump(tester, mesh);

    await tester.tap(_face);
    await tester.pumpAndSettle();

    expect(find.text(_l10n(tester).meshErrorUnsupported), findsOneWidget);
    expect(_face, findsNothing);
    expect(_container(tester).read(meshAvailableProvider), isFalse);
    // The keys the engine took for the start went back with it.
    expect(mesh.journal, containsAllInOrder(['mesh.start', 'mesh.stop']));

    // Nothing the mesh reports later brings it back.
    mesh.radio.emit(radioStatus(MeshRadioState.stopped));
    await tester.pumpAndSettle();
    expect(_face, findsNothing);
  });

  testWidgets('what the button says fits a small phone at 200 % text, with '
      'its remedy within reach', (tester) async {
    final mesh = MeshHarness()..radio.bluetoothOnAnswer = false;
    await _pump(
      tester,
      mesh,
      size: _small,
      textScaler: const TextScaler.linear(2),
    );

    await tester.tap(_face);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final l10n = _l10n(tester);
    const screen = Rect.fromLTWH(0, 0, 320, 568);
    for (final text in [
      l10n.meshErrorBluetoothOff,
      l10n.meshBluetoothSettings,
    ]) {
      final rect = tester.getRect(find.text(text));
      expect(screen.contains(rect.topLeft), isTrue, reason: text);
      expect(screen.contains(rect.bottomRight), isTrue, reason: text);
    }
    expect(_word.evaluate(), isNotEmpty);
    expect(
      tester.getRect(_word.first).overlaps(tester.getRect(_face)),
      isFalse,
    );
    mesh.journal.clear();
    await tester.tap(find.text(l10n.meshBluetoothSettings));
    await tester.pumpAndSettle();
    expect(mesh.journal, ['radio.openBluetoothSettings']);
    expect(find.text(l10n.meshErrorBluetoothOff), findsNothing);
  });

  testWidgets('a word with a remedy stays until it is answered, and gives '
      "way to the button's next: it is not left standing in front of it", (
    tester,
  ) async {
    final mesh = MeshHarness()..radio.bluetoothOnAnswer = false;
    await _pump(tester, mesh);
    final l10n = _l10n(tester);
    await tester.tap(_face);
    await tester.pumpAndSettle();
    expect(find.text(l10n.meshErrorBluetoothOff), findsOneWidget);
    // A remedy is not taken away mid-read.
    await tester.pump(kMeshSaid * 2);
    await tester.pumpAndSettle();
    expect(find.text(l10n.meshErrorBluetoothOff), findsOneWidget);

    // Bluetooth switched on in the shade, the remedy left unanswered.
    mesh.radio.bluetoothOnAnswer = true;
    await tester.tap(_face);
    await tester.pumpAndSettle();

    expect(find.text(l10n.meshErrorBluetoothOff), findsNothing);
    expect(find.text(l10n.meshTurnedOn), findsOneWidget);
  });

  group('a stop the user did not make', () {
    testWidgets('is told beside the button until dismissed, with no cause it '
        'does not know, and to a screen reader, once', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);
      expect(_notice, findsNothing);

      // Hours before its deadline the service says it stopped, and the
      // engine is off.
      mesh.mesh.statsAnswer = meshCounts(on: false);
      mesh.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pumpAndSettle();

      final copy = _l10n(tester).meshStoppedNotice;
      expect(find.descendant(of: _notice, matching: find.text(copy)), findsOne);
      expect(find.text(_l10n(tester).meshStoppedAfterDeadline), findsNothing);
      expect(_shownOn(tester), isFalse);
      expect(announced, [copy]);

      await tester.tap(find.text(_l10n(tester).meshStoppedOk));
      await tester.pump();

      expect(_notice, findsNothing);
      expect(_container(tester).read(meshStoppedNoticeProvider), isFalse);
      expect(announced, [copy]);
    });

    testWidgets('when the twelve hours ran out says so, and only then', (
      tester,
    ) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      mesh.mesh.statsAnswer = meshCounts(onForMs: 60000);
      await _pump(tester, mesh);

      // The deadline passes with the app in front: nothing is reported.
      await tester.pump(const Duration(minutes: 1));
      await tester.pump();

      final copy = _l10n(tester).meshStoppedAfterDeadline;
      expect(copy, 'Bluetooth mesh turned off after 12 hours.');
      expect(find.descendant(of: _notice, matching: find.text(copy)), findsOne);
      expect(announced, [copy]);
      expect(_shownOn(tester), isFalse);
    });

    testWidgets('offers the way back on, through the same turn-on', (
      tester,
    ) async {
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh, introSeen: false);
      mesh.mesh.statsAnswer = meshCounts(on: false);
      mesh.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pumpAndSettle();
      mesh.journal.clear();

      await tester.tap(
        find.descendant(
          of: _notice,
          matching: find.text(_l10n(tester).meshTurnOn),
        ),
      );
      await tester.pumpAndSettle();

      // The disclosure first, as from the button, and nothing started.
      expect(find.byType(MeshIntroSheet), findsOneWidget);
      expect(mesh.journal, isNot(contains('mesh.start')));

      await tester.tap(
        find.descendant(
          of: find.byType(MeshIntroSheet),
          matching: find.text(_l10n(tester).meshTurnOn),
        ),
      );
      await tester.pumpAndSettle();

      expect(mesh.journal, contains('radio.start'));
      expect(_shownOn(tester), isTrue);
      expect(_notice, findsNothing);
    });

    testWidgets('by the reconcile — a radio that stopped beside an engine '
        'still on — is the same notice, shown until seen', (tester) async {
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);

      // The service stopped itself and wants no restart: the reconcile turns
      // the engine off and owes the user the word.
      mesh.radio.emit(radioStatus(MeshRadioState.stopped));
      await tester.pumpAndSettle();

      expect(mesh.journal, contains('mesh.stop'));
      expect(_notice, findsOneWidget);
      await tester.pump(const Duration(minutes: 10));
      expect(_notice, findsOneWidget);

      await tester.tap(find.text(_l10n(tester).meshStoppedOk));
      await tester.pump();
      expect(_notice, findsNothing);
      expect(_container(tester).read(meshStoppedNoticeProvider), isFalse);
    });

    testWidgets('owed from before the map was shown is there when it is', (
      tester,
    ) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh);
      _container(tester).read(meshStoppedNoticeProvider.notifier).state = true;
      await tester.pump();

      expect(_notice, findsOneWidget);
    });

    testWidgets('is withdrawn by turning mesh on again', (tester) async {
      final mesh = MeshHarness();
      await _pump(tester, mesh);
      _container(tester).read(meshStoppedNoticeProvider.notifier).state = true;
      await tester.pump();

      await tester.tap(_face);
      await tester.pumpAndSettle();

      expect(_notice, findsNothing);
    });

    testWidgets('Bluetooth switched off is announced as a pause, and is no '
        'stop', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);

      mesh.radio.emit(radioStatus(MeshRadioState.paused, wanted: true));
      await tester.pumpAndSettle();

      expect(announced, [_l10n(tester).meshNoticePaused]);
      expect(_icon(tester).icon, LucideIcons.bluetoothOff);
      expect(
        find.descendant(of: _face, matching: find.byIcon(LucideIcons.pause)),
        findsOneWidget,
      );
      expect(_notice, findsNothing);

      // Bluetooth back: mesh runs again, and the pause's mark goes.
      mesh.radio.emit(radioStatus(MeshRadioState.running, wanted: true));
      await tester.pumpAndSettle();

      expect(_shownOn(tester), isTrue);
      expect(find.byIcon(LucideIcons.pause), findsNothing);
      expect(announced, [_l10n(tester).meshNoticePaused]);
    });

    testWidgets('a question the radio did not answer is no stop: mesh still '
        'shows on, and nothing is told', (tester) async {
      final announced = captureAccessibilityAnnouncements(tester);
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);

      mesh.radio.throws['status'] = StateError(_address);
      await _container(tester).read(meshProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(mesh.journal, contains('radio.status'));
      expect(_shownOn(tester), isTrue);
      expect(_notice, findsNothing);
      expect(announced, isEmpty);
    });
  });

  group('the statistics sheet opens', () {
    testWidgets('on a hold, with one haptic', (tester) async {
      final haptics = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call.method);
          return null;
        },
      );
      await _pump(tester, MeshHarness());

      await tester.longPress(_face);
      await tester.pumpAndSettle();

      expect(find.byType(MeshStatsSheet), findsOneWidget);
      expect(haptics, hasLength(1));
    });

    testWidgets("on the screen reader's own action, for whoever cannot "
        'hold', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, MeshHarness());

      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        tester.getSemantics(_face).id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
          const CustomSemanticsAction(label: 'Mesh activity'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MeshStatsSheet), findsOneWidget);
      handle.dispose();
    });

    testWidgets('on a tapped notice; "Keep on" restarts the twelve hours '
        'first', (tester) async {
      final mesh = MeshHarness()..on();
      await _pump(tester, mesh);

      mesh.radio.tap(MeshRadioAction.keepOn);
      await tester.pumpAndSettle();

      expect(mesh.count('mesh.keepOn'), 1);
      expect(find.byType(MeshStatsSheet), findsOneWidget);

      // Asked for again while it is open, it is the one sheet.
      mesh.radio.tap(MeshRadioAction.openStats);
      await tester.pumpAndSettle();

      expect(find.byType(MeshStatsSheet), findsOneWidget);
      expect(mesh.count('mesh.keepOn'), 1);
    });
  });
}
