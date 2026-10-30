/// The change card in Circle details: what became of changes to the circle,
/// acknowledged only once the user has read it on screen.
///
/// The promise that makes this a release blocker: an acknowledgement drops
/// every note it read, and dropping a dropped removal's note clears the
/// targets holding the circle's sends. So when a removal the user asked for
/// was dropped and someone it named may still be listed, nothing but an
/// explicit, confirmed "keep them" acknowledges — whatever else holds the
/// circle (AM-D2-1).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circle_attention_provider.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show ChangeNoteFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/bidi_isolate.dart';
import 'package:haven/src/widgets/circles/change_notice_card.dart';
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';

import '../../helpers/fake_change_notices.dart';
import '../../helpers/log_capture.dart';
import '../../helpers/sheet_health_overrides.dart';
import '../../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _bobPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Circle _circle({bool selfIsAdmin = true}) => TestCircleFactory.createCircle(
  mlsGroupId: const [5, 5, 5],
  nostrGroupId: const [6, 6, 6],
  displayName: 'Family',
  members: [
    TestCircleFactory.createMember(
      pubkey: _selfPubkey,
      displayName: 'Me',
      isAdmin: selfIsAdmin,
    ),
    TestCircleFactory.createMember(pubkey: _bobPubkey, displayName: 'Bob'),
  ],
);

class _Harness {
  _Harness({
    List<ChangeNoteFfi> notes = const [],
    List<bool> acks = const [true],
    this.selfIsAdmin = true,
  }) : notices = FakeNoticeManager(notes: notes, acks: acks);

  final FakeNoticeManager notices;
  final bool selfIsAdmin;
  late final MockCircleService service = MockCircleService(
    circles: [_circle(selfIsAdmin: selfIsAdmin)],
  );
  late ProviderContainer container;

  Future<AppLocalizations> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final circle = _circle(selfIsAdmin: selfIsAdmin);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...sheetHealthOverrides(notices: notices),
          circleServiceProvider.overrideWithValue(service),
          selectedCircleProvider.overrideWith((ref) => circle),
          identityProvider.overrideWith(
            (_) async => Identity(
              pubkeyHex: _selfPubkey,
              npub: 'npub1self',
              createdAt: DateTime(2024),
            ),
          ),
          memberLocationsProvider.overrideWith((_) async => const []),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [CirclesBottomSheet(onExpansionChanged: (_) {})],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(CirclesBottomSheet)),
    );
    await tester.tap(find.byKey(WidgetKeys.circleDetailsButton));
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(CirclesBottomSheet)));
  }

  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.byKey(WidgetKeys.leaveCircleCta))).pop();
    await tester.pumpAndSettle();
  }
}

final Finder _card = find.byKey(WidgetKeys.changeNoticeCard);
final Finder _dismiss = find.byKey(WidgetKeys.changeNoticeDismiss);
final Finder _keep = find.byKey(WidgetKeys.changeNoticeKeepMembers);
final Finder _removeAgain = find.byKey(WidgetKeys.changeNoticeRemoveAgain);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the card lists', () {
    testWidgets('each told note in its own sentence; levels are not listed',
        (tester) async {
      final told = ChangeNoteFfi.values
          .where((n) => !const {
                ChangeNoteFfi.unreadChange,
                ChangeNoteFfi.unreadLocation,
                ChangeNoteFfi.awaitsForeground,
                ChangeNoteFfi.routingCollision,
                // The removal form is its own group below.
                ChangeNoteFfi.queuedRemovalDropped,
              }.contains(n))
          .toList();
      final h = _Harness(
        notes: [
          ...told,
          ChangeNoteFfi.awaitsForeground,
          ChangeNoteFfi.routingCollision,
          ChangeNoteFfi.unreadChange,
        ],
      );
      final l10n = await h.open(tester);
      for (final note in told) {
        expect(
          find.text(changeNoteSentence(note, l10n)!),
          findsOneWidget,
          reason: '$note',
        );
      }
      for (final level in const [
        ChangeNoteFfi.awaitsForeground,
        ChangeNoteFfi.routingCollision,
        ChangeNoteFfi.unreadChange,
      ]) {
        expect(changeNoteSentence(level, l10n), isNull, reason: '$level');
      }
      expect(find.text(l10n.changeNoticeHeading), findsOneWidget);
    });

    testWidgets('the card is one live node: heading and notes, buttons '
        'outside it', (tester) async {
      final handle = tester.ensureSemantics();
      final h = _Harness(notes: const [ChangeNoteFfi.changeUndone]);
      final l10n = await h.open(tester);
      final node = tester.getSemantics(
        find.bySemanticsLabel(
          '${l10n.changeNoticeHeading}\n${l10n.changeNoteChangeUndone}',
        ),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(tester.getSemantics(_dismiss).label, contains(l10n.commonDismiss));
      handle.dispose();
    });

    testWidgets('a notice of level notes alone shows no card', (tester) async {
      final h = _Harness(
        notes: const [
          ChangeNoteFfi.awaitsForeground,
          ChangeNoteFfi.routingCollision,
        ],
      );
      await h.open(tester);
      expect(_card, findsNothing);
      expect(h.notices.acknowledged, isEmpty);
    });

    testWidgets('unread locations show as information, with nothing to '
        'acknowledge', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.unreadLocation]);
      final l10n = await h.open(tester);
      expect(find.text(l10n.changeNoteUnreadLocation), findsOneWidget);
      expect(_dismiss, findsNothing);
      expect(h.notices.acknowledged, isEmpty);
    });
  });

  group('acknowledging', () {
    testWidgets('Dismiss acknowledges the notice exactly once', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.changeUndone]);
      await h.open(tester);
      expect(h.notices.acknowledged, isEmpty, reason: 'showing is not reading');

      h.notices.notes = const [];
      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledgedNotes, [
        [ChangeNoteFfi.changeUndone],
      ]);
      expect(_card, findsNothing);
    });

    testWidgets('closing the sheet without pressing acknowledges nothing', (
      tester,
    ) async {
      final h = _Harness(notes: const [ChangeNoteFfi.changeUndone]);
      await h.open(tester);
      await h.close(tester);
      expect(h.notices.acknowledged, isEmpty);
    });

    testWidgets('a notice a write superseded is read and shown again, and '
        'needs its own press', (tester) async {
      final h = _Harness(
        notes: const [ChangeNoteFfi.changeUndone],
        acks: const [false, true],
      );
      final l10n = await h.open(tester);
      h.notices.notes = const [
        ChangeNoteFfi.changeUndone,
        ChangeNoteFfi.mayBeOutOfStep,
      ];
      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledged, hasLength(1), reason: 'refused: stale');
      expect(find.text(l10n.changeNoteMayBeOutOfStep), findsOneWidget);

      h.notices.notes = const [];
      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledgedNotes.last, [
        ChangeNoteFfi.changeUndone,
        ChangeNoteFfi.mayBeOutOfStep,
      ]);
    });

    testWidgets('the same note written again after a Dismiss is offered '
        'again', (tester) async {
      // The fake keeps its notes past an acknowledgement: the re-read finds
      // a new notice holding exactly what the one dismissed held.
      final h = _Harness(notes: const [ChangeNoteFfi.changeUndone]);
      await h.open(tester);
      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledged, hasLength(1));

      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledged, hasLength(2));
      expect(h.notices.acknowledgedNotes.last, [ChangeNoteFfi.changeUndone]);
    });

    testWidgets("an acknowledgement clears the circle's cue", (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.changeUndone]);
      await h.open(tester);
      final key = sharingCircleKey(_circle());
      expect(h.container.read(circleNeedsAttentionProvider(key)), isTrue);
      h.notices.notes = const [];
      await tester.tap(_dismiss);
      await tester.pumpAndSettle();
      expect(h.container.read(circleNeedsAttentionProvider(key)), isFalse);
    });
  });

  group('a note written while Circle details is open', () {
    testWidgets('is shown, in the live node, with no roster or engine-state '
        'change', (tester) async {
      final handle = tester.ensureSemantics();
      final h = _Harness();
      final l10n = await h.open(tester);
      expect(_card, findsNothing, reason: 'premise: no note yet');

      // Every relay refused a commit: a note, and the circle list re-read
      // with nothing about the circle changed.
      h.notices.notes = const [ChangeNoteFfi.changeUndone];
      h.container.invalidate(circlesProvider);
      await tester.pumpAndSettle();

      expect(find.text(l10n.changeNoteChangeUndone), findsOneWidget);
      final node = tester.getSemantics(
        find.bySemanticsLabel(
          '${l10n.changeNoticeHeading}\n${l10n.changeNoteChangeUndone}',
        ),
      );
      expect(
        node.flagsCollection.isLiveRegion,
        isTrue,
        reason: 'the open card speaks it once, as the announcer leaves it',
      );
      handle.dispose();
    });
  });

  group('a dropped removal that may still hold someone', () {
    for (final cause in const [
      null,
      CircleRecoveryCause.awaitingRelays,
      CircleRecoveryCause.stalled,
      CircleRecoveryCause.quarantined,
    ]) {
      testWidgets('offers no plain Dismiss, whatever holds the circle '
          '(${cause?.name ?? 'nothing'})', (tester) async {
        final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
        h.service
          ..unmadeRemoval = const [_bobPubkey]
          ..recoveryCause = cause;
        await h.open(tester);
        expect(_dismiss, findsNothing);
        expect(_keep, findsOneWidget);
      });
    }

    testWidgets('a failed read of who is still listed keeps the form', (
      tester,
    ) async {
      final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
      h.service.unmadeRemovalError = StateError('store down');
      await h.open(tester);
      expect(_dismiss, findsNothing, reason: 'fail closed');
      expect(_keep, findsOneWidget);
    });

    testWidgets('nobody still listed: the plain Dismiss', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
      await h.open(tester);
      expect(_dismiss, findsOneWidget);
      expect(_keep, findsNothing);
    });

    testWidgets('names who is still in the circle: isolated on screen, raw '
        'when spoken', (tester) async {
      final handle = tester.ensureSemantics();
      final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
      h.service.unmadeRemoval = const [_bobPubkey];
      final l10n = await h.open(tester);
      final label = l10n.changeNoticeStillInCircleLabel;
      expect(find.text('$label ${bidiIsolate('Bob')}'), findsOneWidget);
      final spoken = tester.getSemantics(
        find.bySemanticsLabel(RegExp(l10n.changeNoticeStillInCircleLabel)),
      );
      expect(
        spoken.label,
        contains('${l10n.changeNoticeStillInCircleLabel} Bob'),
      );
      expect(spoken.label, isNot(matches(RegExp('[\u2066-\u2069]'))));
      handle.dispose();
    });

    testWidgets('"Keep them" asks first: Cancel is the default and '
        'acknowledges nothing; the confirm, in the error colour, '
        'acknowledges once', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
      h.service.unmadeRemoval = const [_bobPubkey];
      final l10n = await h.open(tester);

      await tester.tap(_keep);
      await tester.pumpAndSettle();
      expect(find.text(l10n.changeNoticeKeepConfirmBody), findsOneWidget);
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.scrollable, isTrue);
      final cancel = tester.widget<TextButton>(
        find.widgetWithText(TextButton, l10n.commonCancel),
      );
      expect(cancel.autofocus, isTrue);
      final confirm = find.byKey(WidgetKeys.changeNoticeKeepConfirm);
      final scheme = Theme.of(tester.element(confirm)).colorScheme;
      expect(
        tester
            .widget<TextButton>(confirm)
            .style!
            .foregroundColor!
            .resolve(const {}),
        scheme.error,
      );

      await tester.tap(find.widgetWithText(TextButton, l10n.commonCancel));
      await tester.pumpAndSettle();
      expect(h.notices.acknowledged, isEmpty);

      await tester.tap(_keep);
      await tester.pumpAndSettle();
      h.notices.notes = const [];
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(h.notices.acknowledgedNotes, [
        [ChangeNoteFfi.queuedRemovalDropped],
      ]);
    });

    testWidgets('"Remove again" removes everyone still listed and '
        'acknowledges nothing', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.queuedRemovalDropped]);
      h.service.unmadeRemoval = const [_bobPubkey];
      await h.open(tester);
      await tester.tap(_removeAgain);
      await tester.pumpAndSettle();
      expect(
        h.service.methodCalls.where((m) => m == 'removeMember'),
        hasLength(1),
      );
      expect(h.notices.acknowledged, isEmpty);
    });

    testWidgets('a member who is no admin is offered Keep, never Remove again',
        (tester) async {
      final h = _Harness(
        notes: const [ChangeNoteFfi.queuedRemovalDropped],
        selfIsAdmin: false,
      );
      h.service.unmadeRemoval = const [_bobPubkey];
      await h.open(tester);
      expect(_removeAgain, findsNothing);
      expect(_keep, findsOneWidget);
      expect(_dismiss, findsNothing);
    });
  });

  group('an undone removal', () {
    testWidgets('"Review members" closes Circle details and asks for the '
        'member list', (tester) async {
      final h = _Harness(notes: const [ChangeNoteFfi.removalUndone]);
      await h.open(tester);
      final before = h.container.read(circleMemberListRequestProvider);
      await tester.tap(find.byKey(WidgetKeys.changeNoticeReviewMembers));
      await tester.pumpAndSettle();
      expect(find.byKey(WidgetKeys.leaveCircleCta), findsNothing);
      expect(h.container.read(circleMemberListRequestProvider), before + 1);
      expect(h.notices.acknowledged, isEmpty);
    });
  });

  group('logs (Rule 15)', () {
    testWidgets('a notice that cannot be read logs only its type', (
      tester,
    ) async {
      final capture = LogCapture.install();
      final h = _Harness()
        ..notices.error = StateError(
          'group 050505 member $_bobPubkey wss://planted.example',
        );
      await h.open(tester);
      capture.restore();
      expect(capture.joined, contains('[Notice] show failed: StateError'));
      expect(capture.joined, contains('[Notice] read failed: StateError'));
      capture.assertNoNeedles(['050505', _bobPubkey, 'wss://planted']);
      expect(_card, findsNothing);
    });
  });
}
