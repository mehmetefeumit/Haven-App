/// The sharing-health banner: what it says, when it says it, and what the one
/// remedy actually does.
///
/// The promise: a pipeline that has stopped delivering is visible, it names the
/// direction that broke (never more than it knows), a screen-reader user is
/// told both when it starts and when it recovers, and the remedy is reachable
/// and actionable rather than decorative.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/sharing_health_banner.dart';

import '../../helpers/localized_app_harness.dart';

final _t0 = DateTime.utc(2026, 8, 28, 12);

/// A [SharingHealthNotifier] with the timer, the FFI and the async derivation
/// removed — the transitions themselves are proved in
/// `sharing_health_provider_test.dart`; this file pins what the UI does with
/// them.
class _StubHealthNotifier extends SharingHealthNotifier {
  _StubHealthNotifier(this._initial);

  final SharingHealth _initial;

  @override
  SharingHealth build() => _initial;

  @override
  Future<void> refresh() async {}

  void moveTo(SharingHealth next) => state = next;
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  late _StubHealthNotifier notifier;
  late int repairCalls;

  late DateTime clock;

  Future<void> pumpBanner(
    WidgetTester tester, {
    required SharingHealth health,
    DateTime? now,
    Future<void> Function()? repair,
    EpochRepairResult? repairResult,
  }) async {
    notifier = _StubHealthNotifier(health);
    repairCalls = 0;
    clock = now ?? _t0.add(const Duration(minutes: 7));
    await pumpLocalized(
      tester,
      const Scaffold(body: SharingHealthBanner()),
      overrides: [
        sharingHealthProvider.overrideWith(() => notifier),
        sharingHealthClockProvider.overrideWithValue(() => clock),
        sharingRepairProvider.overrideWithValue(() async {
          repairCalls++;
          await repair?.call();
          return repairResult;
        }),
      ],
    );
  }

  /// Records every `announce` the widget sends, for the run of one test.
  ///
  /// Spoken-once-and-gone text is the only channel these paths have, so the
  /// tests assert the exact list: an extra announcement is as much a defect as
  /// a missing one (it speaks the same fact twice).
  List<String> captureAnnouncements(WidgetTester tester) {
    final announcements = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (
      dynamic message,
    ) async {
      final map = message! as Map<Object?, Object?>;
      if (map['type'] == 'announce') {
        final data = map['data']! as Map<Object?, Object?>;
        announcements.add(data['message']! as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(
            SystemChannels.accessibility,
            null,
          ),
    );
    return announcements;
  }

  group('what it renders', () {
    testWidgets('nothing at all while the pipeline is healthy', (tester) async {
      // Anti-vacuity for every "is shown" assertion below.
      await pumpBanner(tester, health: SharingHealth.healthy);

      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);
      expect(find.text(l10n.sharingHealthTitleStopped), findsNothing);
      expect(find.text(l10n.sharingHealthTitleNotSending), findsNothing);
      expect(find.text(l10n.sharingHealthTitleNotReceiving), findsNothing);
    });

    testWidgets('a failing send plane claims only that sending stopped', (
      tester,
    ) async {
      await pumpBanner(tester, health: SharingHealth.publishFailing(_t0));

      expect(find.text(l10n.sharingHealthTitleNotSending), findsOneWidget);
      expect(
        find.text(l10n.sharingHealthTitleStopped),
        findsNothing,
        reason: 'receiving may still work; saying sharing stopped would be a '
            'claim the evidence does not support',
      );
    });

    testWidgets('a silent receive plane claims only that receiving stopped', (
      tester,
    ) async {
      await pumpBanner(tester, health: SharingHealth.receiveSilent(_t0));

      expect(find.text(l10n.sharingHealthTitleNotReceiving), findsOneWidget);
      expect(find.text(l10n.sharingHealthTitleStopped), findsNothing);
    });

    testWidgets('a dropped relay connection is the only both-directions '
        'headline', (tester) async {
      await pumpBanner(
        tester,
        health: SharingHealth.paused(
          SharingPausedReason.relayDisconnected,
          _t0,
        ),
      );

      expect(find.text(l10n.sharingHealthTitleStopped), findsOneWidget);
    });

    testWidgets('a deferred send (Unit B) reads as a send fault', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        health: SharingHealth.paused(SharingPausedReason.sendDeferred, _t0),
      );

      expect(find.text(l10n.sharingHealthTitleNotSending), findsOneWidget);
      expect(find.text(l10n.sharingHealthTitleStopped), findsNothing);
    });

    testWidgets('a lost subscription (Unit C) reads as a receive fault', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        health: SharingHealth.paused(
          SharingPausedReason.receiveSubscriptionLost,
          _t0,
        ),
      );

      expect(find.text(l10n.sharingHealthTitleNotReceiving), findsOneWidget);
      expect(find.text(l10n.sharingHealthTitleStopped), findsNothing);
    });

    testWidgets('it clears when the pipeline recovers', (tester) async {
      await pumpBanner(tester, health: SharingHealth.receiveSilent(_t0));
      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsOneWidget);

      notifier.moveTo(SharingHealth.healthy);
      await tester.pumpAndSettle();

      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsNothing);
    });
  });

  group('the age it reports', () {
    testWidgets('is minutes under an hour', (tester) async {
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(minutes: 42)),
      );

      expect(find.text(l10n.sharingHealthNoUpdatesMinutes(42)), findsOneWidget);
    });

    testWidgets('is hours under a day', (tester) async {
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(hours: 5, minutes: 10)),
      );

      expect(find.text(l10n.sharingHealthNoUpdatesHours(5)), findsOneWidget);
    });

    testWidgets('is days beyond that', (tester) async {
      // The overnight case the field incident actually produced: a minutes-only
      // rendering here would read "No updates for about 1980 minutes".
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(days: 1, hours: 9)),
      );

      expect(find.text(l10n.sharingHealthNoUpdatesDays(1)), findsOneWidget);
    });

    testWidgets('follows the clock without any change to the verdict', (
      tester,
    ) async {
      // The regression this guards: a broken pipeline STAYS broken, so the
      // verdict object stops changing while the age keeps growing. If the
      // banner only redrew when the model notified, it would sit at
      // "about 7 minutes" for an hour — a worse lie than showing nothing.
      // Nothing below touches the notifier; only the clock and the banner's
      // own re-render tick move.
      await pumpBanner(tester, health: SharingHealth.publishFailing(_t0));
      expect(find.text(l10n.sharingHealthNoUpdatesMinutes(7)), findsOneWidget);

      clock = _t0.add(const Duration(minutes: 65));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        find.text(l10n.sharingHealthNoUpdatesHours(1)),
        findsOneWidget,
        reason: 'the age must cross the hour boundary on its own',
      );
      expect(find.text(l10n.sharingHealthNoUpdatesMinutes(7)), findsNothing);
    });

    testWidgets('rounds the age to nearest rather than flooring it', (
      tester,
    ) async {
      // 1 h 59 m used to read "about 1 hour" — wrong by nearly an hour, and a
      // broken promise: "about" means nearest, not floor.
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(hours: 1, minutes: 59)),
      );

      expect(find.text(l10n.sharingHealthNoUpdatesHours(2)), findsOneWidget);
    });

    testWidgets('picks the tier by truncation, so 12 h is not "1 day"', (
      tester,
    ) async {
      // Rounding the TIER as well as the value would promote every half-day to
      // "about 1 day". The tier floors; only the value inside it rounds.
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(hours: 12)),
      );

      expect(find.text(l10n.sharingHealthNoUpdatesHours(12)), findsOneWidget);
      expect(find.text(l10n.sharingHealthNoUpdatesDays(1)), findsNothing);
    });
  });

  group('the remedy', () {
    testWidgets('runs the injected repair when tapped', (tester) async {
      await pumpBanner(tester, health: SharingHealth.publishFailing(_t0));

      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      expect(repairCalls, 1);
    });

    testWidgets('keeps its accessible name while it is running', (
      tester,
    ) async {
      // Replacing the label with a bare spinner left the control with NO
      // accessible name (WCAG 2.1 SC 4.1.2) for exactly the seconds a user is
      // most likely to ask what it is doing.
      final gate = Completer<void>();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        repair: () => gate.future,
      );

      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.text(l10n.sharingHealthRepairAction),
        findsOneWidget,
        reason: 'the label must survive the busy state',
      );

      gate.complete();
      await tester.pumpAndSettle();
    });

    testWidgets('announces when a repair did NOT fix it', (tester) async {
      // The banner staying put is the sighted answer; a live region announces
      // its APPEARANCE and never its persistence, so without this a screen
      // reader user gets no outcome at all.
      final announcements = captureAnnouncements(tester);

      await pumpBanner(tester, health: SharingHealth.publishFailing(_t0));
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      expect(announcements, [l10n.sharingHealthRepairUnresolvedAnnouncement]);
    });

    testWidgets('stays silent when the repair DID fix it', (tester) async {
      // Anti-vacuity for the above, and the thing that would actually mislead:
      // announcing failure after a success.
      final announcements = captureAnnouncements(tester);

      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        repair: () async => notifier.moveTo(SharingHealth.healthy),
      );
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      expect(
        announcements,
        [l10n.sharingHealthResumedAnnouncement],
        reason: 'only the recovery announcement, never the unresolved one',
      );
    });

    testWidgets('speaks an epoch outcome exactly once, via the label', (
      tester,
    ) async {
      // Two channels were available and both are wrong on their own: an
      // announcement alone is unreachable after it is spoken (everything under
      // the status node is inside `ExcludeSemantics`), and an announcement ON
      // TOP of the label makes Android say it twice, because a label change on
      // a `liveRegion` node re-announces by itself.
      final announcements = captureAnnouncements(tester);

      await pumpBanner(
        tester,
        health: SharingHealth.receiveSilent(_t0),
        repairResult: const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      final handle = tester.ensureSemantics();
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      expect(
        announcements,
        isEmpty,
        reason: 'the label carries it; announcing too would speak it twice',
      );
      expect(
        find.bySemanticsLabel(
          RegExp(RegExp.escape(l10n.sharingHealthRepairNotOwner)),
        ),
        findsOneWidget,
        reason: 'and a swipe back over the banner must still reach it',
      );
      handle.dispose();
    });

    testWidgets('cannot be re-entered while it is running', (tester) async {
      // The repair re-anchors subscriptions and re-runs a publish burst; a
      // second tap would stack that work on the same MLS session.
      final gate = Completer<void>();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        repair: () => gate.future,
      );

      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pump();
      await tester.tap(
        find.byKey(WidgetKeys.sharingHealthRepairButton),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(repairCalls, 1);

      gate.complete();
      await tester.pumpAndSettle();

      // ...and it becomes usable again once the repair finishes, so a failed
      // repair is not a one-shot.
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();
      expect(repairCalls, 2);
    });
  });

  group('accessibility', () {
    testWidgets('the status is one live region carrying cause AND age', (
      tester,
    ) async {
      // Two orphaned fragments would make a screen-reader user swipe between
      // "sharing stopped" and a bare duration to assemble the sentence.
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(minutes: 9)),
      );

      final node = tester.getSemantics(
        find.bySemanticsLabel(
          '${l10n.sharingHealthTitleNotSending}\n'
          '${l10n.sharingHealthNoUpdatesMinutes(9)}',
        ),
      );
      expect(node.hasFlag(SemanticsFlag.isLiveRegion), isTrue);
    });

    testWidgets('the remedy carries a hint saying what it does', (
      tester,
    ) async {
      // "Repair" alone does not tell a screen-reader user whether they are
      // about to change a setting or grant a permission.
      await pumpBanner(tester, health: SharingHealth.publishFailing(_t0));

      final node = tester.getSemantics(
        find.byKey(WidgetKeys.sharingHealthRepairButton),
      );
      expect(node.hint, contains(l10n.sharingHealthRepairHint));
    });

    testWidgets('the recovery is announced, because a live region never '
        'announces its own removal', (tester) async {
      final announcements = captureAnnouncements(tester);

      await pumpBanner(tester, health: SharingHealth.receiveSilent(_t0));
      expect(announcements, isEmpty, reason: 'nothing recovered yet');

      notifier.moveTo(SharingHealth.healthy);
      await tester.pumpAndSettle();

      expect(announcements, [l10n.sharingHealthResumedAnnouncement]);
    });
  });

  group('layout', () {
    testWidgets('the remedy stays on screen at a 200% text scale', (
      tester,
    ) async {
      // A banner whose only action is below the fold, in a surface with no
      // scroll view of its own, is a banner that cannot be acted on.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      notifier = _StubHealthNotifier(SharingHealth.publishFailing(_t0));
      repairCalls = 0;
      await pumpLocalized(
        tester,
        const Scaffold(
          body: Stack(
            children: [
              PositionedDirectional(
                top: 0,
                bottom: 0,
                start: 0,
                end: 0,
                child: SharingHealthBanner(),
              ),
            ],
          ),
        ),
        textScaler: const TextScaler.linear(2),
        overrides: [
          sharingHealthProvider.overrideWith(() => notifier),
          sharingHealthClockProvider.overrideWithValue(
            () => _t0.add(const Duration(minutes: 7)),
          ),
          sharingRepairProvider.overrideWithValue(() async {
            repairCalls++;
            return null;
          }),
        ],
      );

      expect(tester.takeException(), isNull);
      final button = tester.getRect(
        find.byKey(WidgetKeys.sharingHealthRepairButton),
      );
      expect(button.bottom, lessThanOrEqualTo(640));

      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();
      expect(repairCalls, 1);
    });

    testWidgets('the remedy line fits too, at the same scale', (tester) async {
      // The tallest state the banner can reach: the fault copy, the age line,
      // the action, AND the epoch leg's extra sentence — which only appears
      // after a tap, so the layout above never exercised it.
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      notifier = _StubHealthNotifier(SharingHealth.receiveSilent(_t0));
      await pumpLocalized(
        tester,
        const Scaffold(
          body: Stack(
            children: [
              PositionedDirectional(
                top: 0,
                bottom: 0,
                start: 0,
                end: 0,
                child: SharingHealthBanner(),
              ),
            ],
          ),
        ),
        textScaler: const TextScaler.linear(2),
        overrides: [
          sharingHealthProvider.overrideWith(() => notifier),
          sharingHealthClockProvider.overrideWithValue(
            () => _t0.add(const Duration(minutes: 7)),
          ),
          sharingRepairProvider.overrideWithValue(
            () async => const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
          ),
        ],
      );
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final remedy = tester.getRect(
        find.byKey(const Key('sharing_health_epoch_repair_message')),
      );
      expect(
        remedy.bottom,
        lessThanOrEqualTo(640),
        reason: 'advice the user cannot read is not advice',
      );
    });
  });
}
