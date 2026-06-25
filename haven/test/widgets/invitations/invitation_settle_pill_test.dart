/// Widget tests for [InvitationSettlePill].
///
/// Verifies each visual state renders correctly, that sticky/actionable
/// states expose a working tap action, that calm results auto-hide while
/// problems persist, and that reduced motion drops the spinner animation.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/invitations/invitation_settle_pill.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A notifier whose state can be set directly and whose [refresh] is counted,
/// so widget tests need no relay/identity harness.
class _FakeNotifier extends InvitationPollStatusNotifier {
  _FakeNotifier(this._initial);

  final InvitationPollStatus _initial;
  int refreshCalls = 0;

  @override
  InvitationPollStatus build() => _initial;

  @override
  Future<void> refresh() async => refreshCalls++;

  /// Drives a state transition so the pill's `ref.listen` fires.
  // ignore: use_setters_to_change_properties
  void emit(InvitationPollStatus status) {
    state = status;
  }
}

InvitationPollStatus _settled(
  InvitationPollOutcome outcome, {
  int total = 0,
  int responded = 0,
  int newCount = 0,
}) => InvitationPollStatus(
  phase: InvitationPollPhase.settled,
  total: total,
  responded: responded,
  newCount: newCount,
  outcome: outcome,
);

const _checking = InvitationPollStatus(
  phase: InvitationPollPhase.checking,
  total: 3,
);

Future<_FakeNotifier> _pump(
  WidgetTester tester,
  InvitationPollStatus status, {
  VoidCallback? onConfigureInbox,
  bool reducedMotion = false,
}) async {
  final notifier = _FakeNotifier(status);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        invitationPollStatusProvider.overrideWith(() => notifier),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: Scaffold(
              body: InvitationSettlePill(onConfigureInbox: onConfigureInbox),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return notifier;
}

void main() {
  group('InvitationSettlePill rendering', () {
    testWidgets('checking shows a spinner and calm label', (tester) async {
      await _pump(tester, _checking);

      expect(find.text('Checking your inbox…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // No count is shown while in flight (truthful-by-construction).
      expect(find.textContaining('of'), findsNothing);
    });

    testWidgets('up to date shows the calm "nothing new" line', (tester) async {
      await _pump(
        tester,
        _settled(InvitationPollOutcome.upToDate, total: 3, responded: 3),
      );

      expect(find.text('All answered · nothing new'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);
    });

    testWidgets('multiple new invitations are plural', (tester) async {
      await _pump(
        tester,
        _settled(
          InvitationPollOutcome.newInvites,
          total: 2,
          responded: 2,
          newCount: 2,
        ),
      );
      expect(find.text('2 new invitations'), findsOneWidget);
    });

    testWidgets('a single new invitation is singular', (tester) async {
      await _pump(
        tester,
        _settled(
          InvitationPollOutcome.newInvites,
          total: 1,
          responded: 1,
          newCount: 1,
        ),
      );
      expect(find.text('1 new invitation'), findsOneWidget);
    });

    testWidgets('partial shows exact answered/total and a Retry', (
      tester,
    ) async {
      await _pump(
        tester,
        _settled(InvitationPollOutcome.partial, total: 3, responded: 2),
      );

      expect(find.text('2 of 3 inboxes answered'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(LucideIcons.circleAlert), findsOneWidget);
    });

    testWidgets('offline shows an unreachable message and Retry', (
      tester,
    ) async {
      await _pump(
        tester,
        _settled(InvitationPollOutcome.offline, total: 2),
      );

      expect(find.text("Couldn't reach your inbox"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byIcon(LucideIcons.cloudOff), findsOneWidget);
    });

    testWidgets('no inbox shows Set up only when a handler is provided', (
      tester,
    ) async {
      await _pump(tester, _settled(InvitationPollOutcome.noInbox));
      expect(find.text('No inbox set up'), findsOneWidget);
      expect(find.text('Set up'), findsNothing);

      await _pump(
        tester,
        _settled(InvitationPollOutcome.noInbox),
        onConfigureInbox: () {},
      );
      expect(find.text('Set up'), findsOneWidget);
    });

    testWidgets('idle hides the pill entirely', (tester) async {
      await _pump(tester, InvitationPollStatus.idle);

      expect(find.byKey(WidgetKeys.invitationsSettlePill), findsNothing);
      expect(find.textContaining('inbox'), findsNothing);
    });
  });

  group('InvitationSettlePill actions', () {
    testWidgets('tapping the offline pill triggers a refresh', (tester) async {
      final notifier = await _pump(
        tester,
        _settled(InvitationPollOutcome.offline, total: 2),
      );

      await tester.tap(find.byKey(WidgetKeys.invitationsSettlePill));
      await tester.pump();

      expect(notifier.refreshCalls, 1);
    });

    testWidgets('tapping the no-inbox pill invokes the configure handler', (
      tester,
    ) async {
      var configured = 0;
      await _pump(
        tester,
        _settled(InvitationPollOutcome.noInbox),
        onConfigureInbox: () => configured++,
      );

      await tester.tap(find.byKey(WidgetKeys.invitationsSettlePill));
      await tester.pump();

      expect(configured, 1);
    });
  });

  group('InvitationSettlePill layout', () {
    testWidgets('reserves the same fixed band whether shown or hidden', (
      tester,
    ) async {
      // Hidden (idle) and shown (a settled result) must occupy identical
      // height so the list below never reflows when the pill appears/leaves.
      await _pump(tester, InvitationPollStatus.idle);
      final hiddenHeight = tester
          .getSize(find.byType(InvitationSettlePill))
          .height;

      await _pump(tester, _settled(InvitationPollOutcome.offline, total: 2));
      final shownHeight = tester
          .getSize(find.byType(InvitationSettlePill))
          .height;

      expect(hiddenHeight, greaterThan(0));
      expect(shownHeight, hiddenHeight);
    });
  });

  group('InvitationSettlePill lifecycle', () {
    testWidgets('a calm result auto-hides after the hold duration', (
      tester,
    ) async {
      final notifier = await _pump(tester, _checking);
      // Transition checking -> settled so the auto-hide timer is armed.
      notifier.emit(
        _settled(InvitationPollOutcome.upToDate, total: 3, responded: 3),
      );
      await tester.pump();
      expect(find.text('All answered · nothing new'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text('All answered · nothing new'), findsNothing);
    });

    testWidgets('a problem result stays put (does not auto-hide)', (
      tester,
    ) async {
      final notifier = await _pump(tester, _checking);
      notifier.emit(_settled(InvitationPollOutcome.offline, total: 2));
      await tester.pump();
      expect(find.text("Couldn't reach your inbox"), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));

      expect(find.text("Couldn't reach your inbox"), findsOneWidget);
    });
  });

  group('InvitationSettlePill accessibility', () {
    testWidgets('reduced motion replaces the spinner with a static icon', (
      tester,
    ) async {
      await _pump(tester, _checking, reducedMotion: true);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(LucideIcons.loaderCircle), findsOneWidget);
    });
  });
}
