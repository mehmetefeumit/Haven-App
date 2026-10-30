/// Routing and copy accuracy for the epoch-repair leg of the sharing card.
///
/// The repair is a self-update any member may make. Its outcomes need
/// DIFFERENT words: a success that promised instant recovery would claim what
/// the protocol does not deliver (peers apply the commit when they next
/// receive it), and the engine's own `epochUnrecoverable` refusal is no
/// terminal verdict of its own — it reads a store that did not answer as
/// halted — so whether the circle is halted is the standing cause's to say,
/// read from the core first (decision 313).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/sharing_health_banner.dart';

import '../../helpers/localized_app_harness.dart';
import '../../helpers/sheet_health_overrides.dart';

/// A health notifier parked in a caller-chosen state.
///
/// The verdict matters to every assertion here: the epoch-repair remedies are
/// scoped to RECEIVE-side faults, and a repair that cleared the fault must show
/// no remedy at all.
class _Health extends SharingHealthNotifier {
  _Health(this._initial, {this.after});

  final SharingHealth _initial;

  /// The verdict the model moves to once the repair chain has run.
  final SharingHealth? after;

  @override
  SharingHealth build() => _initial;

  @override
  Future<void> refresh() async {
    if (after != null) state = after!;
  }

  void moveTo(SharingHealth next) => state = next;
}

Circle _circle(int id) => Circle(
  mlsGroupId: [id],
  nostrGroupId: [id],
  displayName: 'c$id',
  circleType: CircleType.locationSharing,
  relays: const [],
  membershipStatus: MembershipStatus.accepted,
  members: const [],
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// The circle the banner is looking at, switchable mid-test.
final _selected = StateProvider<Circle?>((ref) => _circle(1));

/// The one line the epoch leg is allowed to add.
final Finder _remedy = find.byKey(
  const Key('sharing_health_epoch_repair_message'),
);

final _receiveSilent = SharingHealth.receiveSilent(
  DateTime.utc(2026, 8, 28, 12),
);
final _publishFailing = SharingHealth.publishFailing(
  DateTime.utc(2026, 8, 28, 12),
);
final _relayDisconnected = SharingHealth.paused(
  SharingPausedReason.relayDisconnected,
  DateTime.utc(2026, 8, 28, 12),
);

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  late _Health notifier;

  /// Bumped per pump so each one gets a FRESH banner `State`.
  ///
  /// `pumpWidget` reuses the element when the widget type and key match, and
  /// this banner's `State` holds `_repairing` and `_epochOutcome`. Several
  /// tests here pump once per outcome inside one `testWidgets`, so without a
  /// distinct key every iteration after the first would inherit the previous
  /// one's state.
  ///
  /// Nothing is known to leak through it today — both fields are rewritten on
  /// every pump-and-tap, and a `_repairing` genuinely stuck true is caught by
  /// the spinner instead (`pumpAndSettle` never settles), in the keyed shape as
  /// much as the shared one. This is a latent hazard closed cheaply, not a
  /// defect fixed: a future field that is written only on SOME paths would leak
  /// silently, and by then the loops would be proving less than they read as.
  var pumpSeq = 0;

  Future<void> pumpWith(
    WidgetTester tester,
    EpochRepairResult? result, {
    SharingHealth? health,
    SharingHealth? healthAfterRepair,
    bool tap = true,
  }) async {
    notifier = _Health(health ?? _receiveSilent, after: healthAfterRepair);
    pumpSeq++;
    await pumpLocalized(
      tester,
      Scaffold(body: SharingHealthBanner(key: ValueKey(pumpSeq))),
      overrides: [
        ...deviceBannerOverrides(),
        sharingHealthProvider.overrideWith(() => notifier),
        sharingHealthClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 8, 28, 12, 30),
        ),
        selectedCircleProvider.overrideWith((ref) => ref.watch(_selected)),
        sharingRepairProvider.overrideWithValue(() async {
          await notifier.refresh();
          return result;
        }),
      ],
    );
    if (tap) {
      await tester.tap(find.text(l10n.sharingHealthRepairAction));
      await tester.pumpAndSettle();
    }
  }

  group('epoch-repair outcome routing', () {
    testWidgets('Repair is offered to every member: no role is read', (
      tester,
    ) async {
      // `_circle` lists no member at all, so no admin flag exists to read.
      await pumpWith(tester, null, tap: false);
      expect(find.byKey(WidgetKeys.sharingHealthRepairButton), findsOneWidget);
    });

    testWidgets('an engine refusal of a QUARANTINED circle shows the '
        'quarantined cause, never the terminal copy', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
        healthAfterRepair: SharingHealth.paused(
          SharingPausedReason.circleQuarantined,
          DateTime.utc(2026, 8, 28, 12),
        ),
      );
      expect(find.text(l10n.sharingHealthTitleQuarantined), findsOneWidget);
      expect(find.text(l10n.sharingHealthBodyQuarantined), findsOneWidget);
      expect(find.text(l10n.sharingHealthTitleUnrecoverable), findsNothing);
      expect(find.text(l10n.sharingHealthBodyUnrecoverable), findsNothing);
      expect(_remedy, findsNothing);
    });

    testWidgets('an engine refusal with no standing cause claims nothing '
        'terminal, and Repair stays live', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
      );
      expect(_remedy, findsNothing);
      expect(find.text(l10n.sharingHealthBodyUnrecoverable), findsNothing);
      final repair = find.byKey(WidgetKeys.sharingHealthRepairButton);
      expect(tester.widget<TextButton>(repair).onPressed, isNotNull);
    });

    testWidgets('a circle the core reads as halted offers Re-create, and no '
        'Repair', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
        healthAfterRepair: SharingHealth.paused(
          SharingPausedReason.circleUnrecoverable,
          DateTime.utc(2026, 8, 28, 12),
          ageProvable: false,
        ),
      );
      expect(find.text(l10n.sharingHealthBodyUnrecoverable), findsOneWidget);
      expect(find.byKey(WidgetKeys.sharingHealthRecreateCta), findsOneWidget);
      expect(find.byKey(WidgetKeys.sharingHealthRepairButton), findsNothing);
    });

    testWidgets('a successful repair says it was sent, not that it worked', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied());
      expect(find.text(l10n.sharingHealthRepairSent), findsOneWidget);
    });

    testWidgets('a retryable skip still says something', (tester) async {
      // A tap that produces no visible change reads as a broken button. These
      // five gates decline for reasons that clear on their own, so the answer
      // is "nothing to do right now" — not silence, and not a retry prompt.
      for (final reason in const [
        SkipReasonFfi.epochNotStable,
        SkipReasonFfi.recentEpochChange,
        SkipReasonFfi.recentInboundTraffic,
        SkipReasonFfi.pendingProposal,
        SkipReasonFfi.rotatedRecently,
      ]) {
        await pumpWith(tester, EpochRepairSkipped(reason));
        expect(
          find.text(l10n.sharingHealthRepairNothingToDo),
          findsOneWidget,
          reason: '$reason declines for a reason that clears on its own',
        );
        expect(
          find.text(l10n.sharingHealthBodyUnrecoverable),
          findsNothing,
          reason: '$reason is not terminal',
        );
      }
    });

    testWidgets('a deferred repair adds no second message', (tester) async {
      await pumpWith(tester, const EpochRepairDeferred());
      expect(_remedy, findsNothing);
    });
  });

  group('copy accuracy', () {
    testWidgets('no repair string claims forward secrecy', (tester) async {
      await pumpWith(tester, const EpochRepairApplied());
      // The repair gives this circle new keys, and promises nothing about
      // what was sent before.
      const forbidden = ['forward secrecy', 'perfect forward'];
      final strings = [
        l10n.sharingHealthRepairSent,
        l10n.sharingHealthBodyUnrecoverable,
        l10n.sharingHealthRepairHintAnyMember,
      ];
      for (final s in strings) {
        for (final needle in forbidden) {
          expect(
            s.toLowerCase().contains(needle),
            isFalse,
            reason: '"$needle" must not appear in: $s',
          );
        }
      }
    });

    testWidgets('the Repair hint names no role and keeps its "may"', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied(), tap: false);
      final hint = l10n.sharingHealthRepairHintAnyMember;
      expect(
        hint.toLowerCase(),
        isNot(contains('admin')),
        reason: 'any member can repair',
      );
      expect(hint, isNot(contains('if you are')));
      // Several checks decline the key step silently, so a flat indicative
      // would be wrong most of the times it is pressed.
      expect(
        hint,
        contains('may give'),
        reason: 'the key step is a possibility, not a promise',
      );
      for (final overclaim in const [
        'secure again',
        'locks out',
        'no longer read',
      ]) {
        expect(hint.toLowerCase(), isNot(contains(overclaim)));
      }
    });

    testWidgets('the success copy does not promise instant recovery', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied());
      // Peers apply the commit when they next receive it, so delivery does
      // not resume the moment this returns.
      const overclaims = [
        'is working again',
        'restored',
        'fixed',
        'now receiving',
      ];
      final copy = l10n.sharingHealthRepairSent.toLowerCase();
      for (final needle in overclaims) {
        expect(
          copy.contains(needle),
          isFalse,
          reason: '"$needle" promises a recovery the protocol cannot: $copy',
        );
      }
    });

    test('the terminal skip is not offered as retryable', () {
      expect(
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable).isRetryable,
        isFalse,
      );
      for (final reason in const [
        SkipReasonFfi.epochNotStable,
        SkipReasonFfi.recentEpochChange,
        SkipReasonFfi.recentInboundTraffic,
        SkipReasonFfi.pendingProposal,
        SkipReasonFfi.rotatedRecently,
      ]) {
        expect(
          EpochRepairSkipped(reason).isRetryable,
          isTrue,
          reason: '$reason clears on its own and must stay retryable',
        );
      }
    });
  });

  group('the remedy is scoped to what a key update can actually fix', () {
    testWidgets('a repair that CLEARED the fault shows no remedy', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
        healthAfterRepair: SharingHealth.healthy,
      );
      expect(_remedy, findsNothing);
    });

    testWidgets('a SEND-side fault gets no epoch copy at all', (tester) async {
      for (final outcome in const [
        EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
        EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
        EpochRepairApplied(),
      ]) {
        await pumpWith(tester, outcome, health: _publishFailing);
        expect(_remedy, findsNothing, reason: '$outcome against a send fault');
      }
    });

    testWidgets('a SEND-side fault keeps Repair alive', (tester) async {
      for (final health in [_publishFailing, _relayDisconnected]) {
        await pumpWith(
          tester,
          const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
          health: health,
        );
        final button = tester.widget<TextButton>(
          find.byKey(WidgetKeys.sharingHealthRepairButton),
        );
        expect(
          button.onPressed,
          isNotNull,
          reason: 'the epoch verdict does not speak for $health',
        );
      }
    });

    testWidgets('a dropped subscription DOES get the receive-side remedy', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
        health: SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          DateTime.utc(2026, 8, 28, 12),
        ),
      );
      expect(find.text(l10n.sharingHealthRepairNothingToDo), findsOneWidget);
    });
  });

  group('a stale remedy never outlives the incident it described', () {
    testWidgets('it clears when the fault clears', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
      );
      expect(_remedy, findsOneWidget);

      // The card disappears but its `State` does not: `build` returns
      // `SizedBox.shrink()`, it is not unmounted. Without an explicit clear the
      // next unrelated fault re-surfaces this advice.
      notifier.moveTo(SharingHealth.healthy);
      await tester.pumpAndSettle();
      notifier.moveTo(_receiveSilent);
      await tester.pumpAndSettle();

      expect(
        _remedy,
        findsNothing,
        reason: "a new fault must not inherit the previous incident's remedy",
      );
    });

    testWidgets('it clears when the selected circle changes', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
      );
      expect(_remedy, findsOneWidget);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(SharingHealthBanner)),
      );
      container.read(_selected.notifier).state = _circle(2);
      await tester.pumpAndSettle();

      expect(
        _remedy,
        findsNothing,
        reason: 'the advice was about the circle the user just left',
      );
    });
  });

  group('the outcome reaches a screen reader', () {
    testWidgets('it is part of the live-region label, not only spoken', (
      tester,
    ) async {
      // Everything under the status node is inside `ExcludeSemantics`, so a
      // remedy rendered there and announced once is unreachable afterwards.
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
      );
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape(l10n.sharingHealthRepairNothingToDo)),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
