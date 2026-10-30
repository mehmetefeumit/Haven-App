/// Tests for the "Show who" action and [MissedInvitationsDialog].
///
/// The promises: the action is offered only when it can name everyone who
/// was missed; the dialog lists each of them by shortened public key, kept
/// whole in a right-to-left locale; a long press — or the screen reader's
/// named action — copies the FULL key and says so; and at 200% text on a small
/// phone every person and the Close button can be reached.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/missed_invitations_dialog.dart';

import '../../helpers/localized_app_harness.dart';

const _b = 'npub1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _c = 'npub1cccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _d = 'npub1dddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _opener = Key('open_missed_invitations');
const _remedy = 'Circle created. 1 of 3 invitations sent. Remove and re-add.';

String _row(String npub) => bidiIsolate(NpubValidator.shortenForDisplay(npub));

void main() {
  Future<void> openDialog(
    WidgetTester tester,
    List<String> npubs, {
    Locale locale = kDefaultTestLocale,
    TextScaler? textScaler,
  }) async {
    await pumpLocalized(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _opener,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  MissedInvitationsDialog(message: _remedy, npubs: npubs),
            ),
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
      l10nOf(tester, MissedInvitationsDialog);

  group('missedInvitationsAction', () {
    Future<SnackBarAction? Function(List<String>, int, int)> actionFor(
      WidgetTester tester,
    ) async {
      await pumpLocalized(tester, const Scaffold(body: SizedBox()));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      final l10n = l10nOf(tester, Scaffold);
      return (List<String> unsent, int sent, int total) =>
          missedInvitationsAction(
            navigator: navigator,
            l10n: l10n,
            message: _remedy,
            unsent: unsent,
            sent: sent,
            total: total,
          );
    }

    testWidgets('is offered when it names everyone who was missed', (
      tester,
    ) async {
      final action = await actionFor(tester);
      expect(
        action(const [_c, _d], 1, 3)?.label,
        l10nOf(tester, Scaffold).missedInvitationsShowWho,
      );
      expect(action(const [_c], 1, 2), isNotNull, reason: 'one person');
    });

    testWidgets('is not offered when the list would read as all but is not', (
      tester,
    ) async {
      final action = await actionFor(tester);
      expect(action(const [_c], 1, 3), isNull);
      expect(action(const [], 1, 3), isNull);
    });

    testWidgets('is not offered when nobody was sent one: the count already '
        'says it was everyone', (tester) async {
      final action = await actionFor(tester);
      expect(action(const [_b, _c], 0, 2), isNull);
    });

    testWidgets('opens the dialog over whatever route is showing', (
      tester,
    ) async {
      final action = await actionFor(tester);
      action(const [_c, _d], 1, 3)!.onPressed();
      await tester.pumpAndSettle();
      expect(find.byType(MissedInvitationsDialog), findsOneWidget);
      expect(find.text(_row(_c)), findsOneWidget);
      expect(find.text(_row(_d)), findsOneWidget);
    });
  });

  group('MissedInvitationsDialog', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      platformCalls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    List<String> copied() => [
      for (final call in platformCalls)
        if (call.method == 'Clipboard.setData')
          (call.arguments as Map)['text'] as String,
    ];

    testWidgets('lists each person by the shortened, isolated key and is '
        'named by its title', (tester) async {
      await openDialog(tester, const [_b, _c, _d]);
      final title = l10n(tester).missedInvitationsTitle(3);
      expect(find.text(title), findsOneWidget);
      for (final npub in const [_b, _c, _d]) {
        expect(find.text(_row(npub)), findsOneWidget);
        expect(find.text(npub), findsNothing, reason: 'shortened, 12/6');
      }
      expect(
        tester.widget<AlertDialog>(find.byType(AlertDialog)).semanticLabel,
        title,
      );
    });

    testWidgets('one person takes the singular title', (tester) async {
      await openDialog(tester, const [_b]);
      expect(find.text('Invitation not sent'), findsOneWidget);
    });

    testWidgets('it repeats the remedy the snackbar carried, before the list', (
      tester,
    ) async {
      await openDialog(tester, const [_b]);
      expect(
        find.text(_remedy),
        findsOneWidget,
        reason: 'the snackbar that carried it closed when Show who was tapped',
      );
      expect(
        tester.getRect(find.text(_remedy)).bottom,
        lessThanOrEqualTo(tester.getRect(find.text(_row(_b))).top),
      );
    });

    testWidgets('a long press copies the full key and says so in that row, '
        'aloud too', (tester) async {
      await openDialog(tester, const [_b, _c]);
      await tester.longPress(find.text(_row(_c)));
      await tester.pump();

      expect(copied(), [_c]);
      final confirmation = l10n(tester).circleMemberPublicKeyCopied;
      final row = find.ancestor(
        of: find.text(_row(_c)),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: row, matching: find.text(confirmation)),
        findsOneWidget,
        reason: 'a snackbar would sit under the dialog barrier',
      );
      expect(find.byType(SnackBar), findsNothing);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(confirmation),
      );
      await tester.pump(kMissedInvitationCopiedDuration);
      expect(find.text(confirmation), findsNothing, reason: 'then it clears');
    });

    testWidgets('a screen reader can copy through a named action', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await openDialog(tester, const [_b]);
      final hint = l10n(tester).circleMemberCopyPublicKeyHint;
      final node = tester.getSemantics(find.text(_row(_b)));
      final owner = _ancestorWithAction(node, hint);
      expect(owner, isNotNull, reason: 'VoiceOver has no long press');

      final id = owner!.getSemanticsData().customSemanticsActionIds!.firstWhere(
        (id) => CustomSemanticsAction.getAction(id)!.label == hint,
      );
      tester.takeAnnouncements();
      owner.owner!.performAction(owner.id, SemanticsAction.customAction, id);
      await tester.pump();
      expect(copied(), [_b]);
      final confirmation = l10n(tester).circleMemberPublicKeyCopied;
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(confirmation),
        reason: 'the screen reader that asked hears that it worked',
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text(_row(_b)),
            matching: find.byType(ListTile),
          ),
          matching: find.text(confirmation),
        ),
        findsOneWidget,
      );
      await tester.pump(kMissedInvitationCopiedDuration);
      expect(find.text(confirmation), findsNothing, reason: 'then it clears');
      semantics.dispose();
    });

    testWidgets('Close dismisses it', (tester) async {
      await openDialog(tester, const [_b]);
      await tester.tap(
        find.text(
          MaterialLocalizations.of(
            tester.element(find.byType(MissedInvitationsDialog)),
          ).closeButtonLabel,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MissedInvitationsDialog), findsNothing);
    });

    testWidgets('at 200% text on a small phone in German every person and '
        'Close can be reached', (tester) async {
      tester.view
        ..physicalSize = const Size(320, 568)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final many = [
        for (var i = 0; i < 8; i++)
          'npub1${'$i' * 52}qqqqqq',
      ];
      await openDialog(
        tester,
        many,
        locale: const Locale('de'),
        textScaler: const TextScaler.linear(2),
      );
      expect(tester.takeException(), isNull);
      final last = find.text(_row(many.last));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(568));
      final close = find.text('Schließen');
      expect(tester.getRect(close).bottom, lessThanOrEqualTo(568));
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(MissedInvitationsDialog), findsNothing);
    });

    testWidgets('in a right-to-left locale each key stays whole', (
      tester,
    ) async {
      await openDialog(tester, const [_b, _c], locale: const Locale('ar'));
      expect(
        Directionality.of(tester.element(find.text(_row(_b)))),
        TextDirection.rtl,
      );
      for (final npub in const [_b, _c]) {
        final shown = tester.widget<Text>(find.text(_row(npub))).data!;
        expect(shown, startsWith('\u2068'));
        expect(shown, endsWith('\u2069'));
      }
      expect(find.text(l10n(tester).missedInvitationsTitle(2)), findsOneWidget);
    });
  });
}

SemanticsNode? _ancestorWithAction(SemanticsNode node, String label) {
  SemanticsNode? current = node;
  while (current != null) {
    final ids = current.getSemanticsData().customSemanticsActionIds ?? const [];
    if (ids.any((id) => CustomSemanticsAction.getAction(id)?.label == label)) {
      return current;
    }
    current = current.parent;
  }
  return null;
}
