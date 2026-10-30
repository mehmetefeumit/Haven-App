/// The circle details sheet's sharing surface: "sharing is not actually
/// working for this circle, and here is why".
///
/// ## Why the user has to be told at all
///
/// Every failure mode in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` leaves
/// the app looking fine: the circle list renders, the map draws, the foreground
/// service still says "sending and receiving", and the peers' markers simply
/// age out half an hour later. Silence about a broken pipeline is not
/// neutrality — it is the app telling the user something untrue.
///
/// ## Why the headline names a direction
///
/// The pipeline has two independent directions and they fail independently.
/// Telling a user whose sending is broken that "location sharing has stopped"
/// would also claim they cannot see anyone — which may be false, and which
/// changes what they do about it. Collapsing distinct faults into one sentence
/// makes at least one of them a lie in the direction that matters.
///
/// ## Why it lives in Circle details
///
/// The message is said in one place (OD-1): this card, at the top of the
/// circle's details. While the sheet is closed, `SharingHealthAnnouncer`
/// speaks the onset and the recovery and the attention cue marks the circle;
/// neither repeats the message. There is deliberately no dismiss affordance:
/// a dismissible card lets the user hide a condition that is still true.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/clock_skew_provider.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The one action a [SharingHealthCopy] offers.
enum SharingHealthRemedy {
  /// Reconnect, republish and maybe rotate this device's keys.
  repair,

  /// Load a quarantined circle again.
  tryAgain,

  /// Make a new circle with the halted one's name.
  recreate,

  /// No action helps from here; the body says what does, if anything.
  none,
}

/// Title, body, age and remedy for one [SharingHealth] verdict.
@immutable
class SharingHealthCopy {
  /// Creates a resolved copy bundle.
  const SharingHealthCopy({
    required this.title,
    required this.remedy,
    this.body,
    this.age,
  });

  /// Short headline naming WHICH direction stopped, or the cause.
  final String title;

  /// What holds the circle and what, if anything, helps; `null` for a fault
  /// only inferred from delivery evidence.
  final String? body;

  /// How long ago sharing demonstrably worked; `null` when no delivery proves
  /// it ([SharingHealth.ageProvable]) or when the cause is no fault in the
  /// pipeline's age.
  final String? age;

  /// The one action offered.
  final SharingHealthRemedy remedy;
}

/// Maps a [SharingHealth] verdict to its user-facing copy.
///
/// Returns `null` for [SharingHealthState.healthy] — there is nothing to say.
/// Pure (the caller supplies [now]), so every branch is unit-testable without
/// pumping a widget and without a wall clock. Exhaustive with no `_`: a new
/// cause must be placed here deliberately.
SharingHealthCopy? resolveSharingHealthCopy(
  SharingHealth health,
  AppLocalizations l10n,
  DateTime now,
) {
  final since = health.since;
  if (health.state == SharingHealthState.healthy || since == null) return null;
  final age = health.ageProvable
      ? formatSharingHealthAge(l10n, now.difference(since))
      : null;

  SharingHealthCopy copy(
    String title,
    SharingHealthRemedy remedy, {
    String? body,
    bool aged = true,
  }) => SharingHealthCopy(
    title: title,
    body: body,
    age: aged ? age : null,
    remedy: remedy,
  );

  const repair = SharingHealthRemedy.repair;
  const none = SharingHealthRemedy.none;
  switch (health.state) {
    case SharingHealthState.healthy:
      return null;
    case SharingHealthState.publishFailing:
      return copy(l10n.sharingHealthTitleNotSending, repair);
    case SharingHealthState.receiveSilent:
      return copy(l10n.sharingHealthTitleNotReceiving, repair);
    case SharingHealthState.paused:
      return switch (health.pausedReason!) {
        // A dropped relay connection takes both directions with it.
        SharingPausedReason.relayDisconnected => copy(
          l10n.sharingHealthTitleStopped,
          repair,
        ),
        SharingPausedReason.receiveSubscriptionLost => copy(
          l10n.sharingHealthTitleNotReceiving,
          repair,
        ),
        SharingPausedReason.sessionStillHeld => copy(
          l10n.sharingHealthTitleStopped,
          none,
          body: l10n.sharingHealthBodySessionHeld,
        ),
        // The cause is on this phone, not in the pipeline's age.
        SharingPausedReason.circleQuarantined => copy(
          l10n.sharingHealthTitleQuarantined,
          SharingHealthRemedy.tryAgain,
          body: l10n.sharingHealthBodyQuarantined,
          aged: false,
        ),
        // The sheet's own Leave button is the remedy the body names.
        SharingPausedReason.circleDisbanded => copy(
          l10n.sharingHealthTitleDisbanded,
          none,
          body: l10n.sharingHealthBodyDisbanded,
        ),
        SharingPausedReason.circleUnrecoverable => copy(
          l10n.sharingHealthTitleUnrecoverable,
          SharingHealthRemedy.recreate,
          body: l10n.sharingHealthBodyUnrecoverable,
        ),
        SharingPausedReason.routingCollision => copy(
          l10n.sharingHealthTitlePaused,
          none,
          body: l10n.sharingHealthBodyCollision,
        ),
        SharingPausedReason.routingUnchecked => copy(
          l10n.sharingHealthTitlePaused,
          none,
          body: l10n.sharingHealthBodyCannotCheck,
        ),
        SharingPausedReason.leaving => copy(
          l10n.sharingHealthTitleLeaving,
          none,
          body: l10n.sharingHealthBodyLeaving,
        ),
        // No retry helps a stall: an admin re-adding this device does.
        SharingPausedReason.stalled => copy(
          l10n.sharingHealthTitleStalled,
          none,
          body: l10n.sharingHealthBodyStalled,
        ),
        // Decided in the change card or the member list, never by Repair.
        SharingPausedReason.removalUnmade => copy(
          l10n.sharingHealthTitleNotSending,
          none,
          body: l10n.sharingHealthBodyRemovalUnmade,
        ),
        SharingPausedReason.removalUnmadeUntold => copy(
          l10n.sharingHealthTitleNotSending,
          none,
          body: l10n.sharingHealthBodyRemovalUnmadeNoNotice,
        ),
        SharingPausedReason.departureDue => copy(
          l10n.sharingHealthTitleNotSending,
          repair,
          body: l10n.sharingHealthBodyDepartureDue,
        ),
        SharingPausedReason.awaitsForeground => copy(
          l10n.sharingHealthTitleBackgroundPaused,
          repair,
          body: l10n.sharingHealthBodyAwaitsForeground,
        ),
        // A pending change holds the circle both ways (Rule 13.4).
        SharingPausedReason.awaitingRelays => copy(
          l10n.sharingHealthTitleStopped,
          repair,
          body: l10n.sharingHealthBodyAwaitingRelays,
        ),
        SharingPausedReason.acknowledged => copy(
          l10n.sharingHealthTitleStopped,
          repair,
          body: l10n.sharingHealthBodyAcknowledged,
        ),
        SharingPausedReason.stagedWithoutRecord => copy(
          l10n.sharingHealthTitleStopped,
          repair,
          body: l10n.sharingHealthBodyStagedWithoutRecord,
        ),
        SharingPausedReason.storedInput => copy(
          l10n.sharingHealthTitleNotSending,
          repair,
          body: l10n.sharingHealthBodyStoredInput,
        ),
      };
  }
}

/// Formats how long the pipeline has been silent.
///
/// Tiered rather than minutes-only (unlike the map marker's age pill, which is
/// deliberately minutes at every age so a stale marker reads "90m" instead of
/// silently losing its pill): this is a full sentence in a card, and
/// "No updates for about 780 minutes" is a number the reader has to do
/// arithmetic on.
///
/// The TIER is chosen by truncation but the VALUE within it is rounded to
/// nearest. Truncating the value made 1 h 59 m read "about 1 hour", which is
/// wrong by nearly an hour and breaks the promise the word "about" makes —
/// "about" means the nearest value, not the floor. Choosing the tier by
/// truncation instead of rounding is what keeps 12 h from being promoted to
/// "about 1 day"; the cost is a narrow window (23 h 30 m – 23 h 59 m) that
/// reads "about 24 hours", which is clunky but never untrue.
String formatSharingHealthAge(AppLocalizations l10n, Duration age) {
  if (age.inDays >= 1) {
    return l10n.sharingHealthNoUpdatesDays(
      _rounded(age, const Duration(days: 1)),
    );
  }
  if (age.inHours >= 1) {
    return l10n.sharingHealthNoUpdatesHours(
      _rounded(age, const Duration(hours: 1)),
    );
  }
  return l10n.sharingHealthNoUpdatesMinutes(
    _rounded(age, const Duration(minutes: 1)),
  );
}

int _rounded(Duration age, Duration unit) =>
    (age.inMilliseconds / unit.inMilliseconds).round();

/// Card announcing that location sharing is not actually working for the
/// selected circle.
///
/// Renders nothing while the pipeline is healthy, so it is safe to place
/// unconditionally at the top of Circle details. It has no scroll of its own:
/// the sheet scrolls, and the remedy sits outside the status node so it stays
/// its own actionable element.
class SharingHealthBanner extends ConsumerStatefulWidget {
  /// Creates the sharing-health card.
  const SharingHealthBanner({super.key});

  @override
  ConsumerState<SharingHealthBanner> createState() =>
      _SharingHealthBannerState();
}

class _SharingHealthBannerState extends ConsumerState<SharingHealthBanner> {
  /// Whether a repair is in flight.
  ///
  /// The repair re-anchors relay subscriptions and re-runs a publish burst,
  /// which takes seconds. Without this the button would look inert for the
  /// whole of it and invite a second tap onto the same work.
  bool _repairing = false;

  /// The epoch-repair leg's last answer.
  ///
  /// Held rather than shown in a snackbar: covering the screen to repeat what
  /// the card already says takes away information the fault did not.
  ///
  /// CLEARED whenever the fault clears or the selected circle changes — see
  /// [_clearStaleEpochOutcome] — because this `State` outlives both (`build`
  /// returns `SizedBox.shrink()` rather than unmounting).
  EpochRepairResult? _epochOutcome;

  /// Re-renders the age line as time passes.
  ///
  /// The age is a function of the CLOCK, not only of the verdict, so it has
  /// to be redrawn even when the verdict is unchanged — the normal case,
  /// because a broken pipeline stays broken. A card that silently freezes at
  /// "about 7 minutes" for an hour is a worse lie than no card.
  ///
  /// Armed only while there is something to re-render AND somebody able to see
  /// it — see [_armRerender]: a backgrounded app keeps this `State` alive, and
  /// an ungated 72 s tick costs wake-ups for a surface nobody is looking at.
  Timer? _rerender;

  /// Whether the app is foreground-visible: the same signal the health model
  /// gates its own tick on, so the card and its verdict stop and start
  /// together.
  late final ValueListenable<bool> _foreground;

  @override
  void initState() {
    super.initState();
    _foreground = ref.read(sharingHealthForegroundProvider)
      ..addListener(_onForegroundChanged);
  }

  @override
  void dispose() {
    _foreground.removeListener(_onForegroundChanged);
    _rerender?.cancel();
    super.dispose();
  }

  /// Arms or cancels the re-render tick, idempotently. Called from `build`;
  /// it touches no widget state, so it cannot schedule a frame of its own.
  void _armRerender({required bool armed}) {
    if (armed == (_rerender != null)) return;
    if (!armed) {
      _rerender?.cancel();
      _rerender = null;
      return;
    }
    _rerender = Timer.periodic(kSharingHealthTick, (_) {
      if (mounted) setState(() {});
    });
  }

  void _onForegroundChanged() {
    if (!_foreground.value) {
      // A fault drawn while the user looked is one they were told about.
      _announceOnReturn = _shownFault;
      _rerender?.cancel();
      _rerender = null;
      return;
    }
    if (!mounted) return;
    // Re-derive immediately: the first thing a returning user reads must not
    // be the age that was true when they left. `build` re-arms from here.
    setState(() {});
    if (_announceOnReturn) {
      _announceOnReturn = false;
      _announcePersistingFault();
    }
  }

  /// Whether the last build drew a fault.
  bool _shownFault = false;

  /// Whether a fault was already on screen when the app went away; consumed
  /// by the next return.
  bool _announceOnReturn = false;

  /// Speaks the fault once, on return, when it is still there: a live region
  /// announces its APPEARANCE, and this one appeared before the user left, so
  /// coming back to a pipeline that is still broken would otherwise be
  /// completely silent to a screen-reader user.
  void _announcePersistingFault() {
    final shown = ref.read(sharingHealthShownProvider);
    if (!shown.isStopped) return;
    final copy = resolveSharingHealthCopy(
      shown.health,
      AppLocalizations.of(context),
      ref.read(sharingHealthClockProvider)(),
    );
    if (copy == null) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        [copy.title, ?copy.body, ?copy.age].join('\n'),
        Directionality.of(context),
      ),
    );
  }

  /// "Try Again" for a quarantined circle: the only remedy is to load it
  /// again, and none of the repair legs touches that.
  Future<void> _retryQuarantined() async {
    if (_repairing) return;
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final direction = Directionality.of(context);
    setState(() => _repairing = true);
    try {
      await ref.read(sharingQuarantineRetryProvider)();
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
    if (!mounted ||
        ref.read(sharingHealthProvider).pausedReason !=
            SharingPausedReason.circleQuarantined) {
      return;
    }
    // Still quarantined: the card is unchanged, which is silent to a screen
    // reader, so say so once.
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        l10n.sharingHealthQuarantineRetryFailedAnnouncement,
        direction,
      ),
    );
  }

  Future<void> _repair() async {
    if (_repairing) return;
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final direction = Directionality.of(context);
    // Read after the chain whether or not this card is still mounted: the
    // container outlives a closed sheet.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _repairing = true);
    EpochRepairResult? epochResult;
    try {
      epochResult = await ref.read(sharingRepairProvider)();
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
    if (!mounted) {
      // The sheet closed while the repair ran. Its outcome is still owed: a
      // fault that stands is said with the captured view, and a recovery is
      // the announcer's to say.
      if (container.read(sharingHealthShownProvider).isStopped) {
        unawaited(
          SemanticsService.sendAnnouncement(
            view,
            l10n.sharingHealthRepairUnresolvedAnnouncement,
            direction,
          ),
        );
      }
      return;
    }

    // Read the verdict AFTER the whole chain, and let it decide whether any
    // epoch copy is shown at all: if the earlier legs fixed the fault, advice
    // about it is advice about a problem that no longer exists.
    final shown = ref.read(sharingHealthShownProvider);
    if (!shown.isStopped) {
      setState(() => _epochOutcome = null);
      return;
    }

    setState(() => _epochOutcome = epochResult);
    if (_epochCopy(l10n, epochResult, shown.health) != null) {
      // ONE delivery: the outcome is folded into the live-region label, and a
      // label change on a `liveRegion` node re-announces it.
      return;
    }
    // A repair that did not work leaves the card exactly as it was, which is
    // silent to a screen reader: a live region announces its APPEARANCE, and
    // this one never went away.
    unawaited(
      SemanticsService.sendAnnouncement(
        view,
        l10n.sharingHealthRepairUnresolvedAnnouncement,
        direction,
      ),
    );
  }

  /// The line the epoch-repair leg earned, or `null` when it earned none.
  ///
  /// Scoped to the verdict on purpose. The key update repairs a RECEIVE fault
  /// — a peer whose messages this device can no longer decrypt — so its
  /// answer against a send-side fault would send the user after the wrong
  /// problem.
  String? _epochCopy(
    AppLocalizations l10n,
    EpochRepairResult? outcome,
    SharingHealth health,
  ) {
    final isReceiveFault =
        health.state == SharingHealthState.receiveSilent ||
        health.pausedReason == SharingPausedReason.receiveSubscriptionLost;
    // One gate for the whole leg, not per outcome: against a send-side fault
    // even "nothing to repair right now" is wrong, because the user reads it
    // as the verdict on the WHOLE tap.
    if (!isReceiveFault) return null;
    return switch (outcome) {
      // Applied HERE. Every other member applies it when they next receive,
      // so this must not say sharing is working again.
      EpochRepairApplied() => l10n.sharingHealthRepairSent,
      // The standing cause, which the core reads first, says whether the
      // circle is halted: the engine's refusal reads a store that did not
      // answer as halted, so it is no proof of its own, and a quarantined
      // circle must never be told it cannot be repaired.
      EpochRepairSkipped(reason: SkipReasonFfi.epochUnrecoverable) => null,
      // Exhaustive on purpose — no `_`: a new upstream reason must be
      // classified here rather than silently falling into "say nothing".
      EpochRepairSkipped(reason: SkipReasonFfi.epochNotStable) ||
      EpochRepairSkipped(reason: SkipReasonFfi.recentEpochChange) ||
      EpochRepairSkipped(reason: SkipReasonFfi.recentInboundTraffic) ||
      EpochRepairSkipped(reason: SkipReasonFfi.pendingProposal) ||
      EpochRepairSkipped(reason: SkipReasonFfi.rotatedRecently) =>
        l10n.sharingHealthRepairNothingToDo,
      // Queued, or awaiting its relays: the circle's standing cause says so.
      EpochRepairDeferred() => null,
      EpochRepairAwaitingRelays() => null,
      null => null,
    };
  }

  /// Drops an epoch outcome that no longer describes what is on screen: the
  /// fault cleared, or another circle was selected.
  void _clearStaleEpochOutcome() {
    if (_epochOutcome == null) return;
    setState(() => _epochOutcome = null);
  }

  void _openRecreateFlow(Circle? circle) {
    Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CreateCirclePage(initialName: circle?.displayName),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // A live region announces its APPEARANCE but never its removal, so a
    // screen-reader user would otherwise be told sharing stopped and never
    // told it recovered. A verdict going suppressed is no recovery.
    ref
      ..listen<SharingHealthShown>(sharingHealthShownProvider, (
        previous,
        next,
      ) {
        if (!next.isStopped) _clearStaleEpochOutcome();
        // Only the same circle's fault can recover: another circle's healthy
        // verdict says nothing about the fault that was shown.
        if (previous != null &&
            previous.isStopped &&
            next.isRecovered &&
            previous.health.circleKey == next.health.circleKey) {
          unawaited(
            SemanticsService.sendAnnouncement(
              View.of(context),
              l10n.sharingHealthResumedAnnouncement,
              Directionality.of(context),
            ),
          );
        }
      })
      ..listen<Circle?>(selectedCircleProvider, (previous, next) {
        if (previous?.mlsGroupId != next?.mlsGroupId) {
          _clearStaleEpochOutcome();
        }
      });

    final shown = ref.watch(sharingHealthShownProvider);
    final health = shown.health;
    final copy = shown.isStopped
        ? resolveSharingHealthCopy(
            health,
            l10n,
            ref.read(sharingHealthClockProvider)(),
          )
        : null;
    _shownFault = copy != null;
    _armRerender(armed: copy?.age != null && _foreground.value);
    if (copy == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final epochMessage = _epochCopy(l10n, _epochOutcome, health);
    // Under a skewed clock Repair fails again identically; the clock banner
    // names the setting that fixes it. The cause itself still shows.
    final remedy =
        copy.remedy == SharingHealthRemedy.repair &&
            ref.watch(clockSkewProvider).isSkewed
        ? SharingHealthRemedy.none
        : copy.remedy;
    final onError = colorScheme.onErrorContainer;

    // Spaced from the title above only when it renders: an empty card leaves
    // no gap.
    final card = Card(
      key: WidgetKeys.sharingHealthBanner,
      margin: EdgeInsets.zero,
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              // ONE node carrying the cause and what helps, so a screen reader
              // speaks them as a single sentence. `liveRegion` speaks it the
              // moment it appears without stealing focus (WCAG 2.1 SC 4.1.3).
              container: true,
              liveRegion: true,
              // The age is deliberately NOT here: a `liveRegion` re-announces
              // on every label change, and the age changes on every tick. It
              // has its own node below (WCAG 1.3.1).
              explicitChildNodes: true,
              label: [copy.title, ?copy.body, ?epochMessage].join('\n'),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Decorative: the headline beside it carries the meaning.
                  Icon(LucideIcons.radioTower, color: onError),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ExcludeSemantics(
                          child: Text(
                            copy.title,
                            style: textTheme.titleSmall?.copyWith(
                              color: onError,
                            ),
                          ),
                        ),
                        if (copy.body case final body?) ...[
                          const SizedBox(height: HavenSpacing.xs),
                          ExcludeSemantics(
                            child: Text(
                              body,
                              style: textTheme.bodySmall?.copyWith(
                                color: onError,
                              ),
                            ),
                          ),
                        ],
                        // Outside the exclusions on purpose: the one line the
                        // live label does not speak, so its own node is the
                        // only way to read how long the fault has lasted.
                        if (copy.age case final age?) ...[
                          const SizedBox(height: HavenSpacing.xs),
                          Text(
                            age,
                            style: textTheme.bodySmall?.copyWith(
                              color: onError,
                            ),
                          ),
                        ],
                        if (epochMessage != null) ...[
                          const SizedBox(height: HavenSpacing.xs),
                          ExcludeSemantics(
                            child: Text(
                              epochMessage,
                              key: const Key(
                                'sharing_health_epoch_repair_message',
                              ),
                              style: textTheme.bodySmall?.copyWith(
                                color: onError,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (remedy != SharingHealthRemedy.none) ...[
              const SizedBox(height: HavenSpacing.sm),
              // OUTSIDE the status node: the remedy stays its own focusable,
              // actionable element rather than merged into prose.
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: remedy == SharingHealthRemedy.recreate
                    ? TextButton.icon(
                        key: WidgetKeys.sharingHealthRecreateCta,
                        style: TextButton.styleFrom(foregroundColor: onError),
                        onPressed: () =>
                            _openRecreateFlow(ref.read(selectedCircleProvider)),
                        icon: const Icon(LucideIcons.plus),
                        label: Text(l10n.legacyCircleRecreateCta),
                      )
                    : _remedyButton(
                        l10n,
                        colorScheme,
                        quarantined: remedy == SharingHealthRemedy.tryAgain,
                      ),
              ),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(top: HavenSpacing.sm),
      child: card,
    );
  }

  Widget _remedyButton(
    AppLocalizations l10n,
    ColorScheme colorScheme, {
    required bool quarantined,
  }) {
    // `MergeSemantics` is load-bearing: `TextButton` publishes its own
    // container node, so an ancestor hint would otherwise sit in a separate
    // node the screen reader reads apart from the button.
    return MergeSemantics(
      child: Semantics(
        hint: quarantined
            ? l10n.sharingHealthQuarantineRetryHint
            : l10n.sharingHealthRepairHintAnyMember,
        child: TextButton(
          key: WidgetKeys.sharingHealthRepairButton,
          style: TextButton.styleFrom(
            foregroundColor: colorScheme.onErrorContainer,
            // The disabled label must stay legible: Material's default
            // disabled foreground measured 2.5:1 against `errorContainer`,
            // below WCAG 2.1 SC 1.4.3's 4.5:1.
            disabledForegroundColor: colorScheme.onErrorContainer,
          ),
          onPressed: _repairing
              ? null
              : quarantined
              ? _retryQuarantined
              : _repair,
          // The label STAYS while the repair runs, so the control keeps its
          // accessible name (WCAG 2.1 SC 4.1.2).
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_repairing) ...[
                SizedBox.square(
                  dimension: HavenSpacing.base,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(width: HavenSpacing.sm),
              ],
              Flexible(
                child: Text(
                  quarantined
                      ? l10n.commonTryAgain
                      : l10n.sharingHealthRepairAction,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
