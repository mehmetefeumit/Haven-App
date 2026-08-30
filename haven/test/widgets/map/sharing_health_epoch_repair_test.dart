/// Routing and copy accuracy for the epoch-repair leg of the sharing-health
/// banner.
///
/// The repair has three user-visible outcomes and they need DIFFERENT words.
/// Collapsing them is not a cosmetic slip: `notSoleAdmin` and
/// `epochUnrecoverable` never clear by waiting, so presenting either as a retry
/// puts the user in a loop that cannot succeed, and a success that promises
/// instant recovery claims something the protocol does not deliver: peers
/// apply the commit on their own next epoch pass.
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
    testWidgets('a non-owner is told who can repair, not to try again', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      expect(find.text(l10n.sharingHealthRepairNotOwner), findsOneWidget);
      // Never the other two: one would invite a retry that cannot succeed, the
      // other would claim a repair that did not happen.
      expect(find.text(l10n.sharingHealthRepairNeedsNewCircle), findsNothing);
      expect(find.text(l10n.sharingHealthRepairSent), findsNothing);
    });

    testWidgets('an unrecoverable circle is told to be re-created', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
      );
      expect(find.text(l10n.sharingHealthRepairNeedsNewCircle), findsOneWidget);
      expect(find.text(l10n.sharingHealthRepairNotOwner), findsNothing);
    });

    testWidgets('a successful repair says it was sent, not that it worked', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied());
      expect(
        find.text(l10n.sharingHealthRepairSent),
        findsOneWidget,
      );
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
          find.text(l10n.sharingHealthRepairNeedsNewCircle),
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
    testWidgets('no new string claims key rotation or forward secrecy', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied());
      // The repair carries no `UpdatePath`: it resets sender ratchets and
      // provides no post-compromise security. Copy that called it key rotation,
      // or claimed forward secrecy, would be false — the same discipline the
      // Rust side enforces in `circle::rotation`.
      const forbidden = [
        'key rotation',
        'rotate',
        'rotating',
        'forward secrecy',
        'perfect forward',
      ];
      final strings = [
        l10n.sharingHealthRepairSent,
        l10n.sharingHealthRepairNotOwner,
        l10n.sharingHealthRepairNeedsNewCircle,
        l10n.sharingHealthRepairHint,
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

    testWidgets('the Repair hint keeps BOTH of its hedges', (tester) async {
      await pumpWith(tester, const EpochRepairApplied(), tap: false);
      final hint = l10n.sharingHealthRepairHint;
      // (1) ROLE-conditional. Only this circle's sole admin can commit the key,
      // so an unconditional hint promises every user something most of them
      // cannot get.
      expect(
        hint,
        contains('if you are'),
        reason: 'the key clause must stay conditional on being the admin',
      );
      expect(hint.toLowerCase(), contains('admin'));
      // (2) MODAL. Five further gates decline silently even FOR the admin
      // (epoch too recent, circle too busy, a departure pending, already
      // repaired today, engine state unsettled), so a flat indicative would be
      // wrong most of the times the admin presses it.
      expect(
        hint,
        contains('may give'),
        reason: 'five gates can decline; this is a possibility, not a promise',
      );
      // And the thing the hedges must not be traded for: a security claim. The
      // commit carries no `UpdatePath`.
      for (final overclaim in const [
        'secure again',
        'locks out',
        'fresh key',
        'no longer read',
      ]) {
        expect(hint.toLowerCase(), isNot(contains(overclaim)));
      }
    });

    testWidgets('the success copy does not promise instant recovery', (
      tester,
    ) async {
      await pumpWith(tester, const EpochRepairApplied());
      // Peers apply the commit on their own next epoch pass, so delivery does
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

    test('the two terminal skips are not offered as retryable', () {
      // What the banner branches on. If this classification drifts, the UI
      // starts inviting retries that can never succeed.
      expect(
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin).isRetryable,
        isFalse,
      );
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

  group('the remedy is scoped to what a ratchet reset can actually fix', () {
    testWidgets('a repair that CLEARED the fault shows no remedy', (
      tester,
    ) async {
      // The defect this pins: the epoch copy used to be routed before the
      // health model was consulted, so a non-admin whose relay fault the
      // earlier legs had just fixed was still told to ask the admin to re-add
      // them — advice about a problem they no longer had.
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
        healthAfterRepair: SharingHealth.healthy,
      );
      expect(_remedy, findsNothing);
    });

    testWidgets('a SEND-side fault gets no epoch copy at all', (tester) async {
      // A ratchet reset repairs a RECEIVE fault. Offering "ask the admin to
      // re-add you" against a failing publish sends the user after the wrong
      // problem entirely — and so does "nothing to repair right now", which
      // reads as the verdict on the whole tap.
      for (final outcome in const [
        EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
        EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
        EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
        EpochRepairApplied(),
      ]) {
        await pumpWith(tester, outcome, health: _publishFailing);
        expect(_remedy, findsNothing, reason: '$outcome against a send fault');
      }
    });

    testWidgets('a SEND-side fault keeps Repair alive and reasoned', (
      tester,
    ) async {
      // The terminal outcomes disable the button, and that disable has to be
      // gated on the same condition as the copy. Otherwise a send-side fault —
      // where the epoch leg is silent by design — ends with a dead Repair
      // button whose only spoken explanation is "Repair is unavailable for this
      // circle": a verdict the user was never shown, about a fault a ratchet
      // reset was never going to fix.
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
        expect(
          find.bySemanticsLabel(l10n.sharingHealthRepairUnavailableHint),
          findsNothing,
          reason: 'and must not explain a disable that did not happen',
        );
      }
    });

    testWidgets('a dropped subscription DOES get the receive-side remedy', (
      tester,
    ) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
        health: SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          DateTime.utc(2026, 8, 28, 12),
        ),
      );
      expect(find.text(l10n.sharingHealthRepairNeedsNewCircle), findsOneWidget);
    });
  });

  group('a stale remedy never outlives the incident it described', () {
    testWidgets('it clears when the fault clears', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      expect(_remedy, findsOneWidget);

      // The banner disappears but its `State` does not: `build` returns
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
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      expect(_remedy, findsOneWidget);

      // The banner is `const` with no per-circle key, so switching circles
      // keeps this `State`. "Only this circle's admin can repair it" would then
      // name the wrong person's circle.
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

  group('a terminal outcome does not offer a retry', () {
    testWidgets('Repair is disabled and says why', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.epochUnrecoverable),
      );
      final button = tester.widget<TextButton>(
        find.byKey(WidgetKeys.sharingHealthRepairButton),
      );
      expect(
        button.onPressed,
        isNull,
        reason:
            'the copy says the circle cannot be repaired here; leaving the '
            'control live invites a loop that cannot succeed',
      );
      // WCAG 2.1 SC 4.1.2: a disabled control still has to say why.
      expect(
        tester
            .widget<Semantics>(
              find
                  .ancestor(
                    of: find.byKey(WidgetKeys.sharingHealthRepairButton),
                    matching: find.byType(Semantics),
                  )
                  .first,
            )
            .properties
            .hint,
        l10n.sharingHealthRepairUnavailableHint,
      );
    });

    testWidgets('a retryable outcome leaves Repair live', (tester) async {
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.rotatedRecently),
      );
      final button = tester.widget<TextButton>(
        find.byKey(WidgetKeys.sharingHealthRepairButton),
      );
      expect(button.onPressed, isNotNull);
    });
  });

  group('the outcome reaches a screen reader', () {
    testWidgets('it is part of the live-region label, not only spoken', (
      tester,
    ) async {
      // Everything under the status node is inside `ExcludeSemantics`, so a
      // remedy rendered there and announced once is unreachable afterwards: a
      // screen-reader user who swipes back over the banner hears the fault and
      // not what to do about it.
      await pumpWith(
        tester,
        const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape(l10n.sharingHealthRepairNotOwner)),
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

}
