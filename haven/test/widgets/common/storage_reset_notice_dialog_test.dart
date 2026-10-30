/// Tests for [StorageResetNoticeDialog].
///
/// The promises: the notice tells the user what the reset kept, what it
/// removed and that relay settings are back to defaults; it cannot be
/// dismissed without an answer (either answer releases relay-list
/// publishing); each answer is reported as itself, and "Relay settings" is
/// answered only once the user comes back from them; a failed answer says so;
/// and it stays readable and usable by screen reader and keyboard, at 200%
/// text on a small phone, and in a right-to-left locale.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/common/storage_reset_notice_dialog.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/log_capture.dart';

const _opener = Key('open_storage_reset_notice');

void main() {
  late List<StorageResetNoticeChoice?> answers;

  setUp(() => answers = []);

  Future<void> openNotice(
    WidgetTester tester, {
    Locale locale = kDefaultTestLocale,
    TextScaler? textScaler,
  }) async {
    await pumpLocalized(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _opener,
            onPressed: () async =>
                answers.add(await StorageResetNoticeDialog.show(context)),
            child: const Text('open'),
          ),
        ),
      ),
      locale: locale,
      textScaler: textScaler,
    );
    await tester.tap(find.byKey(_opener));
    await tester.pumpAndSettle();
  }

  AppLocalizations l10n(WidgetTester tester) =>
      l10nOf(tester, StorageResetNoticeDialog);

  testWidgets('says what was kept, what was removed and that relays are '
      'back to defaults', (tester) async {
    await openNotice(tester);
    final strings = l10n(tester);

    for (final text in [
      strings.storageResetTitle,
      strings.storageResetKept,
      strings.storageResetLost,
      strings.storageResetRelays,
    ]) {
      expect(find.text(text), findsOneWidget);
    }
  });

  testWidgets('Continue answers continueWithDefaults', (tester) async {
    await openNotice(tester);

    await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
    await tester.pumpAndSettle();

    expect(answers, [StorageResetNoticeChoice.continueWithDefaults]);
    expect(find.byType(StorageResetNoticeDialog), findsNothing);
  });

  testWidgets('Review relay settings answers openRelaySettings', (
    tester,
  ) async {
    await openNotice(tester);
    expect(
      tester
          .getCenter(find.byKey(WidgetKeys.storageResetOpenRelaySettings))
          .dx,
      lessThan(
        tester.getCenter(find.byKey(WidgetKeys.storageResetContinue)).dx,
      ),
      reason: 'left to right, the primary answer sits on the right',
    );

    await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
    await tester.pumpAndSettle();

    expect(answers, [StorageResetNoticeChoice.openRelaySettings]);
  });

  testWidgets('a tap outside does not dismiss it', (tester) async {
    await openNotice(tester);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
    expect(answers, isEmpty);
  });

  testWidgets('the back gesture does not dismiss it', (tester) async {
    await openNotice(tester);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(StorageResetNoticeDialog), findsOneWidget);
    expect(answers, isEmpty);
  });

  testWidgets('both answers are buttons a screen reader can name', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await openNotice(tester);
    final strings = l10n(tester);

    for (final (key, label) in [
      (WidgetKeys.storageResetContinue, strings.storageResetContinue),
      (
        WidgetKeys.storageResetOpenRelaySettings,
        strings.storageResetOpenRelaySettings,
      ),
    ]) {
      expect(
        tester.getSemantics(find.byKey(key)),
        containsSemantics(isButton: true, label: label),
      );
    }
    handle.dispose();
  });

  testWidgets("a screen reader hears the title as the dialog's name and "
      'every paragraph', (tester) async {
    final handle = tester.ensureSemantics();
    await openNotice(tester);
    final strings = l10n(tester);

    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == strings.storageResetTitle &&
            node.getSemanticsData().flagsCollection.namesRoute,
      ),
      findsOne,
      reason: 'the dialog is announced by its title, not as a generic alert',
    );
    for (final paragraph in [
      strings.storageResetKept,
      strings.storageResetLost,
      strings.storageResetRelays,
    ]) {
      expect(find.bySemanticsLabel(paragraph), findsOneWidget);
    }
    handle.dispose();
  });

  testWidgets('keyboard focus stays inside the notice', (tester) async {
    await openNotice(tester);
    final inside = <Key>{
      WidgetKeys.storageResetContinue,
      WidgetKeys.storageResetOpenRelaySettings,
    };

    for (var press = 0; press < 4; press++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context;
      expect(focused, isNotNull);
      var onAnswer = false;
      focused!.visitAncestorElements((element) {
        onAnswer = inside.contains(element.widget.key);
        return !onAnswer;
      });
      expect(
        onAnswer,
        isTrue,
        reason: 'tab must cycle the two answers, never the screen behind',
      );
    }
  });

  testWidgets('at 200% text on a small phone every paragraph can be scrolled '
      'to and both answers stay reachable', (tester) async {
    tester.view
      ..physicalSize = const Size(320, 568)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openNotice(tester, textScaler: const TextScaler.linear(2));
    final strings = l10n(tester);

    expect(tester.takeException(), isNull);
    final relays = find.text(strings.storageResetRelays);
    await tester.ensureVisible(relays);
    await tester.pumpAndSettle();
    final top = tester.getRect(relays).top;
    expect(
      top >= 0 && top < 568,
      isTrue,
      reason: 'the last paragraph can be scrolled onto the screen',
    );
    await tester.ensureVisible(find.byKey(WidgetKeys.storageResetContinue));
    await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
    await tester.pumpAndSettle();

    expect(answers, [StorageResetNoticeChoice.continueWithDefaults]);
  });

  testWidgets('in a right-to-left locale it lays out right to left', (
    tester,
  ) async {
    await openNotice(tester, locale: const Locale('ar'));

    expect(tester.takeException(), isNull);
    expect(
      Directionality.of(tester.element(find.byType(StorageResetNoticeDialog))),
      TextDirection.rtl,
    );
    final strings = l10n(tester);
    expect(find.text(strings.storageResetTitle), findsOneWidget);
    expect(
      tester
          .getCenter(find.byKey(WidgetKeys.storageResetOpenRelaySettings))
          .dx,
      greaterThan(
        tester.getCenter(find.byKey(WidgetKeys.storageResetContinue)).dx,
      ),
      reason: 'the answers mirror: the primary one sits on the left in RTL',
    );

    await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
    await tester.pumpAndSettle();
    expect(answers, [StorageResetNoticeChoice.openRelaySettings]);
  });

  group('answer', () {
    late List<String> steps;
    late bool? acknowledged;
    late int saved;

    Future<void> run(
      WidgetTester tester, {
      Future<void> Function()? acknowledge,
      Future<void> Function()? openRelaySettings,
    }) async {
      steps = [];
      acknowledged = null;
      saved = 0;
      await pumpLocalized(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              key: _opener,
              onPressed: () async {
                acknowledged = await StorageResetNoticeDialog.answer(
                  context,
                  openRelaySettings:
                      openRelaySettings ??
                      () async => steps.add('relay settings'),
                  acknowledge:
                      acknowledge ?? () async => steps.add('acknowledge'),
                  onAcknowledged: () => saved++,
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(_opener));
      await tester.pumpAndSettle();
    }

    testWidgets('Continue acknowledges the reset and opens nothing', (
      tester,
    ) async {
      await run(tester);
      await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
      await tester.pumpAndSettle();

      expect(steps, ['acknowledge']);
      expect(acknowledged, isTrue);
      expect(saved, 1, reason: 'a saved answer is reported once');
    });

    testWidgets('Relay settings opens them first, and coming back is the '
        'answer', (tester) async {
      await run(tester);
      await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
      await tester.pumpAndSettle();

      expect(
        steps,
        ['relay settings', 'acknowledge'],
        reason: "the user's own relays must be in place before anything is "
            'published',
      );
      expect(acknowledged, isTrue);
    });

    testWidgets('nothing is acknowledged while the user is still in Relay '
        'settings', (tester) async {
      final away = Completer<void>();
      await run(tester, openRelaySettings: () => away.future);
      await tester.tap(find.byKey(WidgetKeys.storageResetOpenRelaySettings));
      await tester.pumpAndSettle();

      expect(steps, isEmpty, reason: 'still on the Relay settings page');
      expect(acknowledged, isNull);

      away.complete();
      await tester.pumpAndSettle();
      expect(steps, ['acknowledge']);
      expect(acknowledged, isTrue);
    });

    testWidgets('a failed acknowledgement is reported as unanswered, said on '
        'screen long enough to act on, and logs only its type', (tester) async {
      // Restored inside the body: the widget binding fails a test that ends
      // with `debugPrint` still replaced.
      final logs = LogCapture();
      try {
        await run(
          tester,
          acknowledge: () async => throw StateError('marker at /data/x/y'),
        );
        await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
        await tester.pumpAndSettle();
      } finally {
        logs.restore();
      }

      final l10n = l10nOf(tester, Scaffold);
      expect(acknowledged, isFalse, reason: 'the notice stays owed');
      expect(saved, 0);
      expect(
        find.text(l10n.storageResetAcknowledgeFailed),
        findsOneWidget,
        reason: 'a failed answer is said, not swallowed',
      );
      final snack = tester.widget<SnackBar>(find.byType(SnackBar));
      expect(snack.persist, isTrue);
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.widgetWithText(TextButton, l10n.commonTryAgain),
        ),
        findsOneWidget,
      );
      expect(snack.showCloseIcon, isTrue, reason: 'and it can be closed');
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(
        find.text(l10n.commonTryAgain),
        findsOneWidget,
        reason: 'Try Again stays until the user acts, never on a timer',
      );
      logs
        ..assertContains('StateError')
        ..assertNoNeedles(['/data/x/y']);
    });

    testWidgets('Try Again saves the answer and releases publishing at once', (
      tester,
    ) async {
      var fail = true;
      await run(
        tester,
        acknowledge: () async {
          if (fail) throw StateError('locked');
          steps.add('acknowledge');
        },
      );
      final logs = LogCapture();
      try {
        await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
        await tester.pumpAndSettle();
      } finally {
        logs.restore();
      }
      expect(saved, 0);

      fail = false;
      await tester.tap(find.text(l10nOf(tester, Scaffold).commonTryAgain));
      await tester.pumpAndSettle();

      expect(steps, ['acknowledge']);
      expect(saved, 1, reason: 'no need to wait for the next launch');
    });

    testWidgets('a Try Again that fails again says so again', (tester) async {
      final logs = LogCapture();
      try {
        await run(tester, acknowledge: () async => throw StateError('locked'));
        await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
        await tester.pumpAndSettle();
        final l10n = l10nOf(tester, Scaffold);

        await tester.tap(find.text(l10n.commonTryAgain));
        await tester.pumpAndSettle();
        expect(
          find.text(l10n.storageResetAcknowledgeFailed),
          findsOneWidget,
          reason: 'the second failure is said, not swallowed',
        );
        expect(find.text(l10n.commonTryAgain), findsOneWidget);
        expect(saved, 0);
      } finally {
        logs.restore();
      }
    });

    testWidgets('a Try Again that fails after the app left the screen throws '
        'nothing', (tester) async {
      final retried = Completer<void>();
      var calls = 0;
      final logs = LogCapture();
      try {
        await run(
          tester,
          acknowledge: () {
            calls++;
            return calls == 1
                ? Future<void>.error(StateError('locked'))
                : retried.future;
          },
        );
        await tester.tap(find.byKey(WidgetKeys.storageResetContinue));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10nOf(tester, Scaffold).commonTryAgain));
        await tester.pump();

        await tester.pumpWidget(const SizedBox());
        retried.completeError(StateError('locked'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(saved, 0);
      } finally {
        logs.restore();
      }
    });
  });
}
