/// The sharing-health banner: what it says, when it says it, and what the one
/// remedy actually does.
///
/// The promise: a pipeline that has stopped delivering is visible, it names the
/// direction that broke (never more than it knows), a screen-reader user is
/// told both when it starts and when it recovers, and the remedy is reachable
/// and actionable rather than decorative.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/live_sync_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart'
    show FfiSyncStatusReason, SkipReasonFfi;
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/widgets/map/sharing_health_banner.dart';

import '../../helpers/localized_app_harness.dart';
import '../../mocks/mock_circle_service.dart';

final _t0 = DateTime.utc(2026, 8, 28, 12);

final _identity = Identity(
  pubkeyHex:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  npub: 'npub1self',
  createdAt: DateTime.utc(2026),
);

/// A [CircleHealthService] that has never observed anything.
///
/// "Never observed" is the honest state for the relay-phase scenarios below —
/// and the one that keeps the persisted half of the evidence out of the
/// verdict, so what those tests prove is exactly the phase handling.
class _NoEvidenceHealthService implements CircleHealthService {
  const _NoEvidenceHealthService();

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {}

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => CircleHealthTimestamps.none;
}

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

  /// How many times the banner has re-derived its copy.
  ///
  /// The banner reads the clock exactly once per `build`, and only a `setState`
  /// can rebuild it here (nothing else in the scope changes), so this counts
  /// re-renders — i.e. the wake-ups the re-render tick costs. Asserting on it
  /// rather than on the rendered text is what makes "the tick did not fire"
  /// provable: unchanged text is also what a frozen clock would produce.
  late int copyDerivations;

  Future<void> pumpBanner(
    WidgetTester tester, {
    required SharingHealth health,
    DateTime? now,
    Future<void> Function()? repair,
    EpochRepairResult? repairResult,
    ValueListenable<bool>? foreground,
  }) async {
    notifier = _StubHealthNotifier(health);
    repairCalls = 0;
    copyDerivations = 0;
    clock = now ?? _t0.add(const Duration(minutes: 7));
    await pumpLocalized(
      tester,
      const Scaffold(body: SharingHealthBanner()),
      overrides: [
        sharingHealthProvider.overrideWith(() => notifier),
        sharingHealthClockProvider.overrideWithValue(() {
          copyDerivations++;
          return clock;
        }),
        if (foreground != null)
          sharingHealthForegroundProvider.overrideWithValue(foreground),
        sharingRepairProvider.overrideWithValue(() async {
          repairCalls++;
          await repair?.call();
          return repairResult;
        }),
      ],
    );
  }

  /// A foreground signal the test drives, disposed with the test.
  ValueNotifier<bool> foregroundSignal({bool initial = true}) {
    final signal = ValueNotifier<bool>(initial);
    addTearDown(signal.dispose);
    return signal;
  }

  /// Pumps the banner over the REAL [SharingHealthNotifier] instead of the
  /// stub, and hands back the container driving it.
  ///
  /// Everything the model reads is injected: the clock, the persisted evidence
  /// (none — the scenario this exists for turns entirely on the relay phase),
  /// the selected circle and the identity. Pumped BACKGROUNDED so the model's
  /// periodic re-derivation never arms and every derivation below is one the
  /// test asked for.
  Future<ProviderContainer> pumpRealModel(
    WidgetTester tester, {
    required ValueListenable<bool> foreground,
    required DateTime Function() clock,
  }) async {
    await pumpLocalized(
      tester,
      const Scaffold(body: SharingHealthBanner()),
      overrides: [
        sharingHealthClockProvider.overrideWithValue(clock),
        circleHealthServiceProvider.overrideWithValue(
          const _NoEvidenceHealthService(),
        ),
        selectedCircleProvider.overrideWithValue(
          // A member list is required: an accepted circle with an empty roster
          // is `isLegacyOrphaned`, which the model declines to judge at all.
          TestCircleFactory.createCircle(
            members: [
              TestCircleFactory.createMember(pubkey: _identity.pubkeyHex),
            ],
          ),
        ),
        identityProvider.overrideWith((ref) async => _identity),
        sharingHealthForegroundProvider.overrideWithValue(foreground),
        sharingRepairProvider.overrideWithValue(() async => null),
      ],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SharingHealthBanner)),
    );
    await container.read(identityProvider.future);
    return container;
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

  group('the re-render tick', () {
    testWidgets('stops while backgrounded and re-renders on return', (
      tester,
    ) async {
      // A 72 s periodic wake-up is ~8 wake-ups per 10 minutes. Backgrounded,
      // every one of them redraws a surface nobody can look at — the banner
      // stays mounted returning `SizedBox.shrink()`, so nothing else stops it.
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        foreground: foreground,
      );
      expect(find.text(l10n.sharingHealthNoUpdatesMinutes(7)), findsOneWidget);

      foreground.value = false;
      await tester.pump();
      final derivationsOnLeaving = copyDerivations;

      clock = _t0.add(const Duration(minutes: 65));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        copyDerivations,
        derivationsOnLeaving,
        reason: 'the tick must not wake the app for an off-screen surface',
      );
      expect(
        find.text(l10n.sharingHealthNoUpdatesMinutes(7)),
        findsOneWidget,
        reason: 'nothing re-rendered, so the last visible age is still drawn',
      );

      foreground.value = true;
      await tester.pump();

      expect(
        find.text(l10n.sharingHealthNoUpdatesHours(1)),
        findsOneWidget,
        reason: 'a returning user must not read an age frozen at the moment '
            'they left — and must not have to wait a whole tick for it',
      );
    });

    testWidgets('is not armed at all while the pipeline is healthy', (
      tester,
    ) async {
      // The healthy banner is `SizedBox.shrink()`, so a tick here redraws
      // nothing at all — for the whole time the app is open.
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.healthy,
        foreground: foreground,
      );
      final derivationsWhenHealthy = copyDerivations;

      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        copyDerivations,
        derivationsWhenHealthy,
        reason: 'there is nothing on screen whose age could go stale',
      );
    });

    testWidgets('re-arms when a fault appears and stops when it clears', (
      tester,
    ) async {
      // Anti-vacuity for both gates above: the tick must still do its job in
      // the state the banner exists for, and must not outlive it.
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.healthy,
        foreground: foreground,
      );

      notifier.moveTo(SharingHealth.publishFailing(_t0));
      await tester.pump();
      clock = _t0.add(const Duration(minutes: 65));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        find.text(l10n.sharingHealthNoUpdatesHours(1)),
        findsOneWidget,
        reason: 'a mounted fault still has to follow the clock',
      );

      notifier.moveTo(SharingHealth.healthy);
      await tester.pump();
      final derivationsWhenCleared = copyDerivations;
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        copyDerivations,
        derivationsWhenCleared,
        reason: 'a recovered pipeline must not leave the tick running',
      );
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
    testWidgets('the live region carries the cause, never the age', (
      tester,
    ) async {
      // The age used to be part of this label. A `liveRegion` re-announces on
      // every label change, so a fault that persisted for an hour was spoken
      // over the user roughly every 72 s — the re-render tick's cadence — with
      // nothing new to say. The cause is what changes meaningfully; the age is
      // read on demand from its own node below.
      final handle = tester.ensureSemantics();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(minutes: 9)),
      );

      final node = tester.getSemantics(
        find.bySemanticsLabel(l10n.sharingHealthTitleNotSending),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      expect(
        node.label,
        isNot(contains(l10n.sharingHealthNoUpdatesMinutes(9))),
        reason: 'an age inside a live-region label is re-announced every tick',
      );
      handle.dispose();
    });

    testWidgets('the age is its own non-live node, stable across ticks', (
      tester,
    ) async {
      // WCAG 1.3.1: taking the age out of the live label must not take it out
      // of the accessibility tree — it is on screen, so it must be readable.
      // It sits OUTSIDE the `ExcludeSemantics` subtree that hides the visual
      // copies of everything the live label already speaks.
      final handle = tester.ensureSemantics();
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        now: _t0.add(const Duration(minutes: 9)),
        foreground: foreground,
      );

      final age = tester.getSemantics(
        find.bySemanticsLabel(l10n.sharingHealthNoUpdatesMinutes(9)),
      );
      expect(
        age.flagsCollection.isLiveRegion,
        isFalse,
        reason: 'the age node must never announce itself',
      );

      final liveLabel = find.bySemanticsLabel(
        l10n.sharingHealthTitleNotSending,
      );
      final liveLabelBefore = tester.getSemantics(liveLabel).label;
      clock = _t0.add(const Duration(minutes: 65));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));

      expect(
        tester.getSemantics(liveLabel).label,
        liveLabelBefore,
        reason: 'a tick that only moves the age must leave the live label — '
            'and therefore the announcement — untouched',
      );
      final agedOn = tester.getSemantics(
        find.bySemanticsLabel(l10n.sharingHealthNoUpdatesHours(1)),
      );
      expect(
        agedOn.flagsCollection.isLiveRegion,
        isFalse,
        reason: 'the age still follows the clock, silently',
      );
      handle.dispose();
    });

    testWidgets('the epoch remedy stays in the live label', (tester) async {
      // Anti-regression for the split above: the remedy is the one thing in
      // this banner a user must act on, its visual copy is excluded from the
      // semantics tree, and a live-region label change is how it is delivered.
      final handle = tester.ensureSemantics();
      await pumpBanner(
        tester,
        health: SharingHealth.receiveSilent(_t0),
        repairResult: const EpochRepairSkipped(SkipReasonFfi.notSoleAdmin),
      );
      await tester.tap(find.byKey(WidgetKeys.sharingHealthRepairButton));
      await tester.pumpAndSettle();

      final node = tester.getSemantics(
        find.bySemanticsLabel(
          '${l10n.sharingHealthTitleNotReceiving}\n'
          '${l10n.sharingHealthRepairNotOwner}',
        ),
      );
      expect(node.flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('a resume with a persisting fault announces exactly once', (
      tester,
    ) async {
      // The live region announced its APPEARANCE, which happened before the
      // user left; a still-mounted one never re-fires. Without this, returning
      // to a broken pipeline is completely silent to a screen-reader user.
      final announcements = captureAnnouncements(tester);
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        foreground: foreground,
      );
      expect(announcements, isEmpty, reason: 'nothing has resumed yet');

      foreground.value = false;
      await tester.pump();
      clock = _t0.add(const Duration(minutes: 20));
      foreground.value = true;
      await tester.pump();

      final expected = '${l10n.sharingHealthTitleNotSending}\n'
          '${l10n.sharingHealthNoUpdatesMinutes(20)}';
      expect(announcements, [expected]);

      clock = _t0.add(const Duration(minutes: 22));
      await tester.pump(kSharingHealthTick + const Duration(seconds: 1));
      expect(
        announcements.length,
        1,
        reason: 'the re-render tick must not speak over the user every 72 s',
      );
    });

    testWidgets('a fault that appeared while away is left to the live region', (
      tester,
    ) async {
      // The explicit announcement exists ONLY because a live region that was
      // already on screen does not re-fire. A fault that appeared while the
      // user was away brings a NEW live region with it, and the platform
      // announces that by itself — speaking here too would say it twice.
      final announcements = captureAnnouncements(tester);
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.healthy,
        foreground: foreground,
      );

      foreground.value = false;
      await tester.pump();
      notifier.moveTo(SharingHealth.publishFailing(_t0));
      await tester.pump();
      foreground.value = true;
      await tester.pump();

      expect(find.byKey(WidgetKeys.sharingHealthBanner), findsOneWidget);
      expect(announcements, isEmpty);
    });

    testWidgets('a resume with a cleared fault only announces the recovery', (
      tester,
    ) async {
      // Two announcements here would tell the user sharing is broken and then,
      // in the same breath, that it recovered.
      final announcements = captureAnnouncements(tester);
      final foreground = foregroundSignal();
      await pumpBanner(
        tester,
        health: SharingHealth.publishFailing(_t0),
        foreground: foreground,
      );

      foreground.value = false;
      await tester.pump();
      notifier.moveTo(SharingHealth.healthy);
      await tester.pump();
      foreground.value = true;
      await tester.pump();

      expect(announcements, [l10n.sharingHealthResumedAnnouncement]);
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

    testWidgets('a background pause is never spoken as a recovery', (
      tester,
    ) async {
      // Composed end to end over the REAL notifier, because this is the one
      // promise neither half can prove alone: the banner announces every
      // stopped → healthy edge, and the model is what decides whether a pause
      // produces that edge. A stub told which verdict to hold cannot
      // reproduce a verdict the model derives for itself.
      //
      // The scenario is the reachable one: a single relay of the pool is down
      // while the others still ack publishes, so the send plane never fails
      // and the banner is up on the disconnect alone. The user then
      // backgrounds the app and the first burst pauses the engine. Nothing
      // recovered — the app stopped looking — so nothing may be spoken.
      final announcements = captureAnnouncements(tester);
      final foreground = foregroundSignal(initial: false);
      var now = _t0;
      final container = await pumpRealModel(
        tester,
        foreground: foreground,
        clock: () => now,
      );
      final status = container.read(syncStatusProvider.notifier)
        ..onStatus(FfiSyncStatusReason.disconnected);
      now = _t0.add(
        kSharingFaultConfirmationWindow + const Duration(seconds: 1),
      );
      await container.read(sharingHealthProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(
        find.byKey(WidgetKeys.sharingHealthBanner),
        findsOneWidget,
        reason: 'anti-vacuity: the banner must be up before the pause',
      );
      expect(announcements, isEmpty, reason: 'nothing has resumed yet');

      status.onStatus(FfiSyncStatusReason.paused);
      now = _t0.add(kSharingFaultConfirmationWindow * 10);
      await container.read(sharingHealthProvider.notifier).refresh();
      await tester.pumpAndSettle();

      expect(announcements, isEmpty);
      expect(
        find.byKey(WidgetKeys.sharingHealthBanner),
        findsOneWidget,
        reason: 'the relay is still down; the banner has nothing to retract',
      );
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
