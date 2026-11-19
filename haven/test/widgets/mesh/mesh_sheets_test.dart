// The Bluetooth mesh's two sheets: its statistics and its disclosure
// (`docs/BLUETOOTH_MESH_PLAN.md` §0.4, §7.5, §7.6;
// `docs/BLUETOOTH_MESH_M3_DESIGN.md` §D, §E.2–§E.4).
//
//  * the statistics sheet shows the four counts, one status line and when
//    mesh turns itself off; it drives the mesh once when it opens and reads
//    the state afresh, and again each minute the app is in front; "Keep on"
//    moves the time; a reset asks first; the counts are shown and never
//    logged, and a count is never broken or cut, at any text size;
//  * it turns mesh on and off through the mesh button's own flow, and says
//    what came of it in the sheet;
//  * a screen reader reads it in order, each count as one node that says
//    what it counts;
//  * the disclosure says the phone's Bluetooth name where it can be read,
//    opens the system's Bluetooth settings, and reads the name again on the
//    way back;
//  * both hold at 200 % text on a small phone and in a right-to-left
//    language;
//  * the Settings row is there where a radio is, and opens the same sheet.
import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/settings/settings_page.dart';
import 'package:haven/src/providers/mesh_provider.dart';
import 'package:haven/src/services/mesh_radio.dart';
import 'package:haven/src/widgets/common/settings_tile.dart';
import 'package:haven/src/widgets/mesh/mesh_intro_sheet.dart';
import 'package:haven/src/widgets/mesh/mesh_stats_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';
import '../../helpers/mesh_ui_harness.dart';

const _name = "Ada's Pixel 9";

/// Opens [show] from a button, as the map and the Settings page do.
Future<void> _open(
  WidgetTester tester,
  MeshHarness mesh,
  Future<void> Function(BuildContext context) show, {
  Size size = const Size(390, 844),
  Locale locale = kDefaultTestLocale,
  TextScaler? textScaler,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await pumpLocalized(
    tester,
    Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => show(context),
          child: const Text('open'),
        ),
      ),
    ),
    overrides: mesh.overrides,
    locale: locale,
    textScaler: textScaler,
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _openStats(
  WidgetTester tester,
  MeshHarness mesh, {
  Size size = const Size(390, 844),
  Locale locale = kDefaultTestLocale,
  TextScaler? textScaler,
}) => _open(
  tester,
  mesh,
  showMeshStatsSheet,
  size: size,
  locale: locale,
  textScaler: textScaler,
);

AppLocalizations _l10n(WidgetTester tester, Type sheet) =>
    AppLocalizations.of(tester.element(find.byType(sheet)));

/// Every label in the semantics tree under the sheet, in reading order, but
/// the route's own.
List<String> _read(WidgetTester tester, Type sheet) {
  final route = MaterialLocalizations.of(
    tester.element(find.byType(sheet)),
  ).dialogLabel;
  final labels = <String>[];
  void visit(SemanticsNode node) {
    if (node.label.isNotEmpty && node.label != route) labels.add(node.label);
    for (final child in node.debugListChildrenInOrder(
      DebugSemanticsDumpOrder.traversalOrder,
    )) {
      visit(child);
    }
  }

  visit(tester.getSemantics(find.byType(sheet)));
  return labels;
}

/// The app goes through [states], and is back in front when the test ends.
void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  states.forEach(tester.binding.handleAppLifecycleStateChanged);
  addTearDown(
    () => tester.binding.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    ),
  );
}

void main() {
  setUp(
    () => SharedPreferences.setMockInitialValues({kMeshIntroSeenKey: true}),
  );

  group('the statistics sheet', () {
    testWidgets('shows the four counts under what each counts, and a screen '
        'reader reads the sheet in order with each count as one node', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final mesh = MeshHarness()
        ..on(linked: true)
        ..mesh.statsAnswer = meshCounts(
          linked: true,
          fromCirclesSinceOn: 12,
          fromCirclesTotal: 3401,
          passedOnSinceOn: 57,
          passedOnTotal: 21048,
        );
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);

      for (final count in ['12', '3,401', '57', '21,048']) {
        expect(find.text(count), findsOneWidget);
      }
      expect(find.text('Received from your circles'), findsOneWidget);
      expect(find.text('Passed on for others'), findsOneWidget);
      expect(find.text('This session'), findsNWidgets(2));
      expect(find.text('All time'), findsNWidgets(2));
      expect(find.text(l10n.meshStatsLastSession), findsNothing);

      final until = tester
          .widgetList<Text>(find.byType(Text))
          .map((text) => text.data!)
          .singleWhere((text) => text.startsWith('Turns off at '));
      expect(_read(tester, MeshStatsSheet), [
        l10n.meshStatsTitle,
        l10n.meshStatusConnected,
        until,
        l10n.meshTurnOff,
        l10n.meshKeepOn,
        'Received from your circles, This session: 12',
        'Received from your circles, All time: 3,401',
        'Passed on for others, This session: 57',
        'Passed on for others, All time: 21,048',
        l10n.meshStatsFootnote,
        l10n.meshStatsAbout,
        l10n.meshStatsReset,
      ]);
      expect(
        tester.getSemantics(find.text(l10n.meshStatsTitle)),
        matchesSemantics(label: l10n.meshStatsTitle, isHeader: true),
      );
      handle.dispose();
    });

    testWidgets('a count is never broken over two lines or cut: on a small '
        'phone at 200 % text each is one line, whole, with its caption '
        'under it', (tester) async {
      final mesh = MeshHarness()..on(linked: true);
      mesh.mesh.statsAnswer = meshCounts(
        linked: true,
        fromCirclesSinceOn: 12,
        fromCirclesTotal: 1480,
        passedOnSinceOn: 3,
        passedOnTotal: 96204,
      );
      await _openStats(
        tester,
        mesh,
        size: const Size(320, 568),
        textScaler: const TextScaler.linear(2),
      );

      expect(tester.takeException(), isNull);
      for (final (count, caption) in [
        ('12', 'This session'),
        ('1,480', 'All time'),
        ('3', 'This session'),
        ('96,204', 'All time'),
      ]) {
        final text = find.text(count);
        await tester.ensureVisible(text);
        await tester.pumpAndSettle();
        final paragraph = tester.renderObject<RenderParagraph>(text);
        final lines = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: 0, extentOffset: count.length),
            )
            .map((box) => box.top.round())
            .toSet();
        expect(lines, hasLength(1), reason: '$count is broken over lines');
        expect(paragraph.didExceedMaxLines, isFalse, reason: count);
        final rect = tester.getRect(text);
        expect(rect.left, greaterThanOrEqualTo(0), reason: count);
        expect(rect.right, lessThanOrEqualTo(320), reason: count);
        // Its caption is the next thing under it, in its own column.
        final captions = tester
            .widgetList<Text>(find.text(caption))
            .map((widget) => tester.getRect(find.byWidget(widget)))
            .where(
              (under) =>
                  (under.left - rect.left).abs() < 1 &&
                  under.top >= rect.bottom - 1,
            );
        expect(captions, isNotEmpty, reason: '$count has lost its caption');
      }
      // Digits of one width: a count that changes does not shift.
      expect(
        tester.widget<Text>(find.text('96,204')).style!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('drives the mesh once when it opens and then reads the '
        'state; each minute after it reads again, and drives no more; away, '
        'no timer of its runs', (tester) async {
      final mesh = MeshHarness()..on();
      mesh.mesh.onDrive = () => mesh.journal.add('mesh.drive!');
      await _openStats(tester, mesh);

      expect(mesh.count('mesh.drive'), 1);
      expect(
        mesh.journal.indexOf('mesh.drive'),
        lessThan(mesh.journal.lastIndexOf('mesh.stats')),
      );
      expect(find.text('0'), findsNWidgets(4));

      // What the mesh did meanwhile is on the sheet a minute later.
      mesh.mesh.statsAnswer = meshCounts(passedOnSinceOn: 9, passedOnTotal: 9);
      mesh.journal.clear();
      await tester.pump(kMeshStatsRefresh);
      await settleMesh(tester);

      expect(mesh.journal, contains('mesh.stats'));
      expect(mesh.journal, isNot(contains('mesh.drive')));
      expect(find.text('9'), findsNWidgets(2));

      // Away, the session is the background's: nothing is read.
      _lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);
      mesh.journal.clear();
      await tester.pump(kMeshStatsRefresh * 3);
      await settleMesh(tester);

      expect(mesh.journal, isEmpty);

      // And a minute after the return, it reads again.
      _lifecycle(tester, [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pump(kMeshStatsRefresh);
      await settleMesh(tester);

      expect(mesh.journal, contains('mesh.stats'));
      expect(mesh.journal, isNot(contains('mesh.drive')));
    });

    testWidgets('says in one line what mesh is doing, and offers what fits '
        'it', (tester) async {
      for (final (state, linked, canSearch, line) in [
        (MeshRadioState.running, true, true, 'Mesh is on · connected'),
        (
          MeshRadioState.running,
          false,
          true,
          'Mesh is on · looking for nearby phones',
        ),
        (
          MeshRadioState.running,
          false,
          false,
          "Mesh is on · other phones can find this one, but it can't look "
              'for them',
        ),
        (
          MeshRadioState.paused,
          false,
          true,
          'Mesh is paused · Bluetooth is off',
        ),
        (MeshRadioState.stopped, false, true, 'Mesh is off'),
      ]) {
        final mesh = MeshHarness();
        if (state != MeshRadioState.stopped) {
          mesh.on(linked: linked, state: state, canSearch: canSearch);
        }
        await _openStats(tester, mesh);
        final l10n = _l10n(tester, MeshStatsSheet);

        expect(find.text(line), findsOneWidget, reason: line);
        expect(find.textContaining('Mesh is '), findsOneWidget, reason: line);
        // When it turns off, the way to keep it and the way to turn it off,
        // only while it is on; the way to turn it on, only while it is off.
        final on = state != MeshRadioState.stopped;
        Matcher there({required bool when}) =>
            when ? findsOneWidget : findsNothing;
        expect(find.textContaining('Turns off at'), there(when: on));
        expect(find.text(l10n.meshKeepOn), there(when: on), reason: line);
        expect(find.text(l10n.meshTurnOff), there(when: on), reason: line);
        expect(find.text(l10n.meshTurnOn), there(when: !on), reason: line);
        // Paused is Bluetooth switched off: the way to switch it on is here.
        expect(
          find.text(l10n.meshBluetoothSettings),
          there(when: state == MeshRadioState.paused),
          reason: line,
        );
        if (state == MeshRadioState.paused) {
          mesh.journal.clear();
          await tester.tap(find.text(l10n.meshBluetoothSettings));
          await tester.pump();
          expect(mesh.journal, ['radio.openBluetoothSettings']);
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('with mesh off the first column is the last session, whose '
        'counts the store keeps until the next', (tester) async {
      final mesh = MeshHarness();
      mesh.mesh.statsAnswer = meshCounts(
        on: false,
        fromCirclesSinceOn: 12,
        fromCirclesTotal: 1480,
        passedOnSinceOn: 3,
        passedOnTotal: 96204,
      );
      await _openStats(tester, mesh);

      expect(find.text('Last session'), findsNWidgets(2));
      expect(find.text('This session'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Last session: 12')), findsOneWidget);
      expect(find.text('Mesh is off'), findsOneWidget);
    });

    testWidgets("turns mesh on through the button's own flow — the "
        'disclosure first, the name before anything is stored — and off '
        'again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final mesh = MeshHarness()..radio.bluetoothNameAnswer = _name;
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);
      mesh.journal.clear();

      await tester.tap(find.text(l10n.meshTurnOn));
      await tester.pumpAndSettle();

      expect(find.byType(MeshIntroSheet), findsOneWidget);
      expect(
        mesh.journal.where((call) => call != 'radio.bluetoothName'),
        isEmpty,
      );

      await tester.tap(
        find.descendant(
          of: find.byType(MeshIntroSheet),
          matching: find.text(l10n.meshTurnOn),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.meshNameStepTitle), findsOneWidget);
      expect(mesh.journal, isNot(contains('mesh.start')));

      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(l10n.meshTurnOn),
        ),
      );
      await tester.pumpAndSettle();

      expect(mesh.journal, containsAllInOrder(['mesh.start', 'radio.start']));
      expect(find.byType(MeshStatsSheet), findsOneWidget);
      expect(find.text(l10n.meshStatusSearching), findsOneWidget);
      // Said by the sheet's own line: a snackbar would be under it.
      expect(find.byType(SnackBar), findsNothing);

      await tester.tap(find.text(l10n.meshTurnOff));
      await tester.pumpAndSettle();

      expect(mesh.journal, containsAllInOrder(['radio.stop', 'mesh.stop']));
      expect(find.text(l10n.meshStatusOff), findsOneWidget);
    });

    testWidgets('a turn-on that failed is said in the sheet, in the same '
        'words and with the same remedy as from the button', (tester) async {
      final mesh = MeshHarness()..radio.bluetoothOnAnswer = false;
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);

      await tester.tap(find.text(l10n.meshTurnOn));
      await tester.pumpAndSettle();

      expect(find.text(l10n.meshErrorBluetoothOff), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      mesh.journal.clear();
      await tester.tap(find.text(l10n.meshBluetoothSettings));
      await tester.pump();
      expect(mesh.journal, ['radio.openBluetoothSettings']);

      // Bluetooth on: the failure's word goes with the next try, not at
      // its end, and the try goes through.
      mesh.radio.bluetoothOnAnswer = true;
      final start = Completer<void>();
      mesh.mesh.held['start'] = start.future;
      await tester.tap(find.text(l10n.meshTurnOn));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(mesh.journal, contains('mesh.start'));
      expect(find.text(l10n.meshErrorBluetoothOff), findsNothing);
      start.complete();
      await tester.pumpAndSettle();

      expect(find.text(l10n.meshErrorBluetoothOff), findsNothing);
      expect(find.text(l10n.meshStatusSearching), findsOneWidget);
    });

    testWidgets('"Keep on" restarts the twelve hours and moves the time '
        'shown', (tester) async {
      final mesh = MeshHarness()..on();
      mesh.mesh.statsAnswer = meshCounts(onForMs: 30 * 60 * 1000);
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);
      String shown(Duration left) => l10n.meshTurnsOffAt(clock.now().add(left));
      expect(find.text(shown(const Duration(minutes: 30))), findsOneWidget);

      mesh.mesh.statsAnswer = meshCounts();
      await tester.tap(find.text(l10n.meshKeepOn));
      await tester.pumpAndSettle();

      expect(mesh.count('mesh.keepOn'), 1);
      expect(find.text(shown(const Duration(hours: 12))), findsOneWidget);
      expect(find.text(shown(const Duration(minutes: 30))), findsNothing);
    });

    testWidgets('a reset asks first, and zeroes all four only on "Reset"', (
      tester,
    ) async {
      final mesh = MeshHarness()..on();
      mesh.mesh.statsAnswer = meshCounts(
        fromCirclesSinceOn: 3,
        fromCirclesTotal: 4,
        passedOnSinceOn: 5,
        passedOnTotal: 6,
      );
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);

      await tester.tap(find.text(l10n.meshStatsReset));
      await tester.pumpAndSettle();
      expect(find.text(l10n.meshStatsResetTitle), findsOneWidget);
      expect(find.text(l10n.meshStatsResetBody), findsOneWidget);
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      expect(mesh.journal, isNot(contains('mesh.resetCounts')));
      expect(find.text('6'), findsOneWidget);

      await tester.tap(find.text(l10n.meshStatsReset));
      await tester.pumpAndSettle();
      // The bridge forgets them.
      mesh.mesh.statsAnswer = meshCounts();
      await tester.tap(find.text(l10n.meshStatsResetConfirm));
      await tester.pumpAndSettle();

      expect(mesh.count('mesh.resetCounts'), 1);
      expect(find.text('0'), findsNWidgets(4));
    });

    testWidgets('counts that could not be read are said so in fixed words, '
        'with a way to ask again — and the counts of an earlier read are '
        'not left standing as if they were now', (tester) async {
      final mesh = MeshHarness()..on();
      mesh.mesh.statsAnswer = meshCounts(passedOnTotal: 7341);
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);
      expect(find.text('7,341'), findsOneWidget);

      mesh.mesh.throws['stats'] = StateError('group AA:BB:CC:DD:EE:FF');
      await tester.pump(kMeshStatsRefresh);
      await settleMesh(tester);

      expect(find.text(l10n.meshStatsUnavailable), findsOneWidget);
      expect(find.text('7,341'), findsNothing);
      expect(find.textContaining('AA:BB'), findsNothing);
      expect(find.text(l10n.meshStatsReset), findsNothing);

      mesh.mesh.throws.clear();
      await tester.tap(find.text(l10n.commonRetry));
      await tester.pumpAndSettle();

      expect(find.text(l10n.meshStatsUnavailable), findsNothing);
      expect(find.text('7,341'), findsOneWidget);
    });

    testWidgets('the counts are shown and never logged', (tester) async {
      final logs = LogCapture();
      final mesh = MeshHarness()..on();
      mesh.mesh.statsAnswer = meshCounts(
        fromCirclesSinceOn: 48213,
        fromCirclesTotal: 59324,
        passedOnSinceOn: 61435,
        passedOnTotal: 72546,
      );
      await _openStats(tester, mesh);
      await tester.pump(kMeshStatsRefresh);
      await settleMesh(tester);
      logs.restore();

      expect(find.text('72,546'), findsOneWidget);
      for (final count in ['48213', '59324', '61435', '72546', '48,213']) {
        expect(logs.joined, isNot(contains(count)));
      }
    });

    testWidgets('holds at 200 % text on a small phone, and in Arabic: every '
        'line and action can be reached', (tester) async {
      for (final (locale, scale) in [
        (const Locale('en'), 2.0),
        (const Locale('ar'), 1.0),
        (const Locale('ar'), 2.0),
      ]) {
        final mesh = MeshHarness()..on(linked: true);
        mesh.mesh.statsAnswer = meshCounts(
          linked: true,
          fromCirclesSinceOn: 123456,
          fromCirclesTotal: 12345678,
          passedOnSinceOn: 123456,
          passedOnTotal: 12345678,
        );
        await _openStats(
          tester,
          mesh,
          size: const Size(320, 568),
          locale: locale,
          textScaler: TextScaler.linear(scale),
        );
        final l10n = _l10n(tester, MeshStatsSheet);
        final row = '$locale x$scale';

        expect(tester.takeException(), isNull, reason: row);
        for (final text in [
          l10n.meshStatsTitle,
          l10n.meshTurnOff,
          l10n.meshStatsFootnote,
          l10n.meshKeepOn,
          l10n.meshStatsAbout,
          l10n.meshStatsReset,
        ]) {
          await tester.ensureVisible(find.text(text));
          await tester.pumpAndSettle();
          final rect = tester.getRect(find.text(text));
          expect(rect.left, greaterThanOrEqualTo(0), reason: '$row $text');
          expect(rect.right, lessThanOrEqualTo(320), reason: '$row $text');
          expect(rect.bottom, lessThanOrEqualTo(568), reason: '$row $text');
        }
        expect(tester.takeException(), isNull, reason: row);
        // Every action is at least the minimum touch target.
        for (final button in [
          l10n.meshTurnOff,
          l10n.meshKeepOn,
          l10n.meshStatsReset,
        ]) {
          final target = tester.getSize(
            find.ancestor(
              of: find.text(button),
              matching: find.bySubtype<ButtonStyleButton>(),
            ),
          );
          expect(
            target.height,
            greaterThanOrEqualTo(48),
            reason: '$row $button',
          );
        }
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('opens the disclosure again, to be read and not to turn '
        'anything on', (tester) async {
      final mesh = MeshHarness()
        ..on()
        ..radio.bluetoothNameAnswer = _name;
      await _openStats(tester, mesh);
      final l10n = _l10n(tester, MeshStatsSheet);

      await tester.ensureVisible(find.text(l10n.meshStatsAbout));
      await tester.tap(find.text(l10n.meshStatsAbout));
      await tester.pumpAndSettle();

      expect(find.byType(MeshIntroSheet), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(MeshIntroSheet),
          matching: find.text(l10n.meshTurnOn),
        ),
        findsNothing,
      );
      expect(find.textContaining(_name), findsOneWidget);
      await tester.tap(find.text(l10n.commonBack));
      await tester.pumpAndSettle();
      expect(find.byType(MeshIntroSheet), findsNothing);
      expect(find.byType(MeshStatsSheet), findsOneWidget);
    });
  });

  group('the disclosure', () {
    Future<void> openIntro(
      WidgetTester tester,
      MeshHarness mesh, {
      Size size = const Size(390, 844),
      Locale locale = kDefaultTestLocale,
      TextScaler? textScaler,
    }) => _open(
      tester,
      mesh,
      (context) => showMeshIntroSheet(context, offerTurnOn: true),
      size: size,
      locale: locale,
      textScaler: textScaler,
    );

    testWidgets("opens the system's Bluetooth settings, and shows the name "
        'as it is on the way back', (tester) async {
      final mesh = MeshHarness()..radio.bluetoothNameAnswer = _name;
      await openIntro(tester, mesh);
      final l10n = _l10n(tester, MeshIntroSheet);
      expect(find.textContaining(_name), findsOneWidget);

      await tester.ensureVisible(find.text(l10n.meshBluetoothSettings));
      await tester.tap(find.text(l10n.meshBluetoothSettings));
      await tester.pump();
      expect(mesh.count('radio.openBluetoothSettings'), 1);

      // Renamed there.
      mesh.radio.bluetoothNameAnswer = 'Phone';
      _lifecycle(tester, [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);
      await tester.pumpAndSettle();

      expect(find.textContaining(_name), findsNothing);
      expect(
        find.text(
          "Your phone's Bluetooth name is \u201c\u2068Phone\u2069\u201d.",
        ),
        findsOneWidget,
      );
    });

    testWidgets('holds at 200 % text on a small phone, and in Arabic: every '
        'paragraph can be reached and both actions stay in view', (
      tester,
    ) async {
      for (final (locale, scale) in [
        (const Locale('en'), 2.0),
        (const Locale('ar'), 2.0),
      ]) {
        final mesh = MeshHarness()..radio.bluetoothNameAnswer = _name;
        await openIntro(
          tester,
          mesh,
          size: const Size(320, 568),
          locale: locale,
          textScaler: TextScaler.linear(scale),
        );
        final l10n = _l10n(tester, MeshIntroSheet);
        final row = '$locale x$scale';

        expect(tester.takeException(), isNull, reason: row);
        for (final action in [l10n.commonCancel, l10n.meshTurnOn]) {
          final rect = tester.getRect(find.text(action));
          expect(
            const Rect.fromLTWH(0, 0, 320, 568).contains(rect.center),
            isTrue,
            reason: '$row $action',
          );
        }
        await tester.scrollUntilVisible(
          find.text(l10n.meshIntroStats),
          200,
          scrollable: find
              .descendant(
                of: find.byType(MeshIntroSheet),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        final last = tester.getRect(find.text(l10n.meshIntroStats));
        expect(last.left, greaterThanOrEqualTo(0), reason: row);
        expect(last.right, lessThanOrEqualTo(320), reason: row);
        expect(tester.takeException(), isNull, reason: row);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('the Settings row', () {
    Future<void> pumpSettings(WidgetTester tester, MeshHarness? mesh) =>
        pumpLocalized(
          tester,
          const SettingsPage(),
          overrides: mesh?.overrides ?? const [],
        );

    testWidgets('says whether mesh is on, and opens the statistics sheet', (
      tester,
    ) async {
      for (final (state, subtitle) in [
        (MeshRadioState.stopped, 'Off'),
        (MeshRadioState.running, 'On'),
        (MeshRadioState.paused, 'On'),
      ]) {
        final mesh = MeshHarness();
        if (state != MeshRadioState.stopped) mesh.on(state: state);
        await pumpSettings(tester, mesh);
        await settleMesh(tester);
        final row = find.widgetWithText(HavenSettingsTile, 'Bluetooth mesh');

        expect(row, findsOneWidget);
        expect(
          find.descendant(of: row, matching: find.text(subtitle)),
          findsOneWidget,
          reason: '$state',
        );
        // After Location, as designed.
        expect(
          tester.getTopLeft(row).dy,
          greaterThan(
            tester
                .getTopLeft(find.widgetWithText(HavenSettingsTile, 'Location'))
                .dy,
          ),
        );

        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.byType(MeshStatsSheet), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('is not there where there is no radio', (tester) async {
      await pumpSettings(tester, null);

      expect(find.text('Bluetooth mesh'), findsNothing);
      expect(find.byIcon(Icons.bluetooth), findsNothing);
      // The rows the page has without the mesh.
      expect(find.byType(HavenSettingsTile), findsNWidgets(6));
    });

    testWidgets("is not there on a phone that answered it can't use mesh: "
        'no row that leads to a control that could never work', (tester) async {
      final mesh = MeshHarness()
        ..radio.startAnswer = MeshRadioStart.unsupported;
      await pumpSettings(tester, mesh);
      await settleMesh(tester);
      final l10n = AppLocalizations.of(
        tester.element(find.byType(SettingsPage)),
      );
      await tester.tap(
        find.widgetWithText(HavenSettingsTile, 'Bluetooth mesh'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10n.meshTurnOn));
      await tester.pumpAndSettle();

      // Said where the user is, with nothing left to press that could never
      // work; and the row behind the sheet is gone.
      expect(find.text(l10n.meshErrorUnsupported), findsOneWidget);
      expect(find.text(l10n.meshTurnOn), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.byType(MeshStatsSheet), findsNothing);
      expect(find.text('Bluetooth mesh'), findsNothing);
      expect(find.byType(HavenSettingsTile), findsNWidgets(6));
    });
  });
}
