/// The map's "sharing is not actually working" surface.
///
/// ## Why the user has to be told at all
///
/// Every failure mode in `docs/BACKGROUND_SHARING_FAILURE_ANALYSIS.md` leaves
/// the app looking fine: the circle list renders, the map draws, the foreground
/// service still says "sending and receiving", and the peers' markers simply
/// age out half an hour later. The field incident took two devices and hours to
/// notice. Silence about a broken pipeline is not neutrality — it is the app
/// telling the user something untrue.
///
/// ## Why three headlines and not one
///
/// The pipeline has two independent directions and they fail independently.
/// Telling a user whose sending is broken that "location sharing has stopped"
/// would also claim they cannot see anyone — which may be false, and which
/// changes what they do about it. Same shape as `ClockSkewBanner`'s two bodies:
/// collapsing distinct faults into one sentence makes at least one of them a
/// lie in the direction that matters.
///
/// ## Why a banner and not a dialog
///
/// A broken send plane says nothing about the peers' locations already on the
/// map, and vice versa. Covering the map would remove information the fault did
/// not take away. There is deliberately no dismiss affordance: a dismissible
/// banner lets the user hide a condition that is still true and still losing
/// their updates.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show SkipReasonFfi;
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Title and body for one [SharingHealth] verdict.
@immutable
class SharingHealthCopy {
  /// Creates a resolved copy bundle.
  const SharingHealthCopy({required this.title, required this.message});

  /// Short headline naming WHICH direction stopped.
  final String title;

  /// Body dating the last moment sharing demonstrably worked.
  final String message;
}

/// Maps a [SharingHealth] verdict to its user-facing copy.
///
/// Returns `null` for [SharingHealthState.healthy] — there is nothing to say.
/// Pure (the caller supplies [now]), so every branch is unit-testable without
/// pumping a widget and without a wall clock.
SharingHealthCopy? resolveSharingHealthCopy(
  SharingHealth health,
  AppLocalizations l10n,
  DateTime now,
) {
  final since = health.since;
  if (health.state == SharingHealthState.healthy || since == null) return null;

  final String title;
  switch (health.state) {
    case SharingHealthState.healthy:
      return null;
    case SharingHealthState.publishFailing:
      title = l10n.sharingHealthTitleNotSending;
    case SharingHealthState.receiveSilent:
      title = l10n.sharingHealthTitleNotReceiving;
    case SharingHealthState.paused:
      switch (health.pausedReason!) {
        // A dropped relay connection takes both directions with it; the other
        // two causes are one-directional and must not claim more than they are.
        case SharingPausedReason.relayDisconnected:
          title = l10n.sharingHealthTitleStopped;
        case SharingPausedReason.sendDeferred:
          title = l10n.sharingHealthTitleNotSending;
        case SharingPausedReason.receiveSubscriptionLost:
          title = l10n.sharingHealthTitleNotReceiving;
      }
  }

  return SharingHealthCopy(
    title: title,
    message: formatSharingHealthAge(l10n, now.difference(since)),
  );
}

/// Formats how long the pipeline has been silent.
///
/// Tiered rather than minutes-only (unlike the map marker's age pill, which is
/// deliberately minutes at every age so a stale marker reads "90m" instead of
/// silently losing its pill): this is a full sentence in a banner, and
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

/// Banner announcing that location sharing is not actually working.
///
/// Renders nothing while the pipeline is healthy, so it is safe to place
/// unconditionally in the map stack.
///
/// ## Height, and why the caller must bound it
///
/// Same shape as `LocationAccessBanner`: the card shrink-wraps, and at the
/// 200 % text scale both platforms offer this content is taller than a small
/// phone's viewport. The status text therefore sits in a
/// [SingleChildScrollView] under a [Flexible] and the remedy button is OUTSIDE
/// it, so the button is the last thing laid out and is always reachable. That
/// only holds if the incoming constraints have a bounded height, which
/// `MapShell` supplies by giving the banner slot a `bottom:` as well as a
/// `top:`.
class SharingHealthBanner extends ConsumerStatefulWidget {
  /// Creates the sharing-health banner.
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
  /// The OUTCOME is held, not a rendered string, because two things derive from
  /// it: the line of copy, and whether Repair may be pressed again at all. A
  /// terminal outcome must disable the control, so a rendered string alone
  /// would lose the half that matters.
  ///
  /// Held rather than shown in a snackbar for the same reason the banner never
  /// uses one: covering the map to repeat what the banner already says takes
  /// away information the fault did not.
  ///
  /// CLEARED whenever the fault clears or the selected circle changes — see
  /// [_clearStaleEpochOutcome]. Without that, a past incident's "only this
  /// circle's admin can repair it" reappears on the next unrelated fault, and
  /// on a different circle, because this `State` outlives both (`build` returns
  /// `SizedBox.shrink()` rather than unmounting, and the widget is `const` with
  /// no per-circle key).
  EpochRepairResult? _epochOutcome;

  /// Re-renders the age line as time passes.
  ///
  /// The body is a function of the CLOCK, not only of the verdict, so it has to
  /// be redrawn even when the verdict is unchanged — which is the normal case,
  /// because a broken pipeline stays broken. Relying on the model to notify
  /// would tie the rendered age to whether `SharingHealth` happened to compare
  /// unequal AND to whether the model's own tick is armed (it is suspended
  /// while the app is backgrounded), and a banner that silently freezes at
  /// "about 7 minutes" for an hour is a worse lie than no banner.
  ///
  /// Owned here, not in the model, because this is a presentation cadence: the
  /// timer only exists while the banner is mounted, i.e. while the map is on
  /// screen and no higher-precedence banner has taken the slot.
  ///
  /// Armed only while there is something to re-render AND somebody able to see
  /// it — see [_armRerender]. Mounted is NOT the same as visible here: the
  /// healthy banner is `SizedBox.shrink()` rather than an unmounted widget, and
  /// a backgrounded app keeps this `State` alive, so an ungated 72 s tick costs
  /// about eight wake-ups per ten minutes for a surface nobody is looking at.
  Timer? _rerender;

  /// Whether the app is foreground-visible.
  ///
  /// The same signal the health model gates its own tick on, so the banner and
  /// the verdict behind it stop and start together.
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

  /// Arms or cancels the re-render tick, idempotently.
  ///
  /// Called from `build` because [armed] depends on the copy `build` derives;
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
      // An armed tick is exactly the condition "a fault is drawn and the user
      // is looking at it" — i.e. one they have already been told about. A
      // fault that appears while they are AWAY brings a new live region with
      // it, which the platform announces on its own.
      _announceOnReturn = _rerender != null;
      _rerender?.cancel();
      _rerender = null;
      return;
    }
    if (!mounted) return;
    // Re-derive immediately rather than at the next tick: the first thing a
    // returning user reads must not be the age that was true when they left.
    // `build` re-arms from here.
    setState(() {});
    if (_announceOnReturn) {
      _announceOnReturn = false;
      _announcePersistingFault();
    }
  }

  /// Whether a fault was already on screen when the app went away.
  ///
  /// Consumed by the next return: see [_onForegroundChanged].
  bool _announceOnReturn = false;

  /// Speaks the fault once, on return, when it is still there.
  ///
  /// A live region announces its APPEARANCE, and this one appeared before the
  /// user left; it is still mounted, and its label no longer carries the age,
  /// so nothing re-announces it. Without this, coming back to a pipeline that
  /// is still broken is completely silent to a screen-reader user.
  ///
  /// Derived from the verdict as it is at this instant — the same one `build`
  /// is about to draw. When the fault cleared while the app was away the model
  /// has already published `healthy` (its own listener runs on the same
  /// signal), so this finds no copy and the recovery announcement in `build` is
  /// the only thing spoken.
  void _announcePersistingFault() {
    final copy = resolveSharingHealthCopy(
      ref.read(sharingHealthProvider),
      AppLocalizations.of(context),
      ref.read(sharingHealthClockProvider)(),
    );
    if (copy == null) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        '${copy.title}\n${copy.message}',
        Directionality.of(context),
      ),
    );
  }

  Future<void> _repair() async {
    if (_repairing) return;
    final l10n = AppLocalizations.of(context);
    final view = View.of(context);
    final direction = Directionality.of(context);
    setState(() => _repairing = true);
    EpochRepairResult? epochResult;
    try {
      epochResult = await ref.read(sharingRepairProvider)();
    } finally {
      if (mounted) setState(() => _repairing = false);
    }
    if (!mounted) return;

    // Read the health model AFTER the whole chain, and let it decide whether
    // any epoch copy is shown at all.
    //
    // The epoch leg is one of four remedies the chain runs, and it is the only
    // one that can decline for a reason peculiar to the caller. If the earlier
    // legs actually fixed the fault, telling a non-admin "ask this circle's
    // admin to remove you and add you back" is advice to act on a problem that
    // no longer exists — the reason this used to be routed unconditionally is
    // simply that it returned before ever consulting the verdict.
    final health = ref.read(sharingHealthProvider);
    if (!health.isStopped) {
      setState(() => _epochOutcome = null);
      return;
    }

    setState(() => _epochOutcome = epochResult);
    if (_epochCopy(l10n, epochResult, health) != null) {
      // ONE delivery. The outcome is folded into the live-region label, and a
      // label change on a `liveRegion` node re-announces it on Android — so an
      // explicit `sendAnnouncement` here would speak it twice.
      return;
    }
    // A repair that did not work leaves the banner exactly as it was, which
    // reads to a sighted user as "tried, no luck" but is completely silent to
    // a screen reader: a live region announces its APPEARANCE, and this one
    // never went away. No snackbar — the persisting banner is already the
    // visible answer, and covering the map to repeat it would take away
    // information the fault did not.
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
  /// Scoped to the verdict on purpose. A ratchet reset repairs a RECEIVE fault
  /// — a peer whose messages this device can no longer decrypt — so offering
  /// "ask this circle's admin to re-add you" or "make a new circle" against a
  /// send-side fault (`publishFailing`) or a dropped subscription
  /// (`sendDeferred`, `relayDisconnected`) would send the user after the wrong
  /// problem entirely.
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
    // as the verdict on the WHOLE tap, and the other three legs did run and
    // did not fix it. The unresolved announcement is the honest answer there.
    if (!isReceiveFault) return null;
    return switch (outcome) {
      // The commit is published and applied HERE. Every other member applies it
      // when they next receive, and only starts sending readable locations
      // after that — so this must not say sharing is working again.
      EpochRepairApplied() => l10n.sharingHealthRepairSent,
      // Only this circle's admin can author the commit, and there is no message
      // the app can send on the user's behalf.
      EpochRepairSkipped(reason: SkipReasonFfi.notSoleAdmin) =>
        l10n.sharingHealthRepairNotOwner,
      // Terminal: this never clears by waiting, so no retry is offered.
      EpochRepairSkipped(reason: SkipReasonFfi.epochUnrecoverable) =>
        l10n.sharingHealthRepairNeedsNewCircle,
      // Exhaustive on purpose — no `_`. A new upstream reason must be
      // classified here rather than silently falling into "say nothing", which
      // is how a tap becomes unexplained.
      EpochRepairSkipped(reason: SkipReasonFfi.epochNotStable) ||
      EpochRepairSkipped(reason: SkipReasonFfi.recentEpochChange) ||
      EpochRepairSkipped(reason: SkipReasonFfi.recentInboundTraffic) ||
      EpochRepairSkipped(reason: SkipReasonFfi.pendingProposal) ||
      EpochRepairSkipped(reason: SkipReasonFfi.rotatedRecently) =>
        l10n.sharingHealthRepairNothingToDo,
      // The engine queued the work instead of staging it; the other legs' own
      // outcome is the honest answer here.
      EpochRepairDeferred() => null,
      null => null,
    };
  }

  /// Drops an epoch outcome that no longer describes what is on screen.
  ///
  /// Two edges, both reproduced: the fault clearing (the advice is now about a
  /// problem the user no longer has) and the selected circle changing (the
  /// advice was about a DIFFERENT circle, and "this circle's admin" would name
  /// the wrong person).
  void _clearStaleEpochOutcome() {
    if (_epochOutcome == null) return;
    setState(() => _epochOutcome = null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // A live region announces its APPEARANCE but never its removal, so a
    // screen-reader user would otherwise be told sharing stopped and never told
    // it recovered. Announce the recovery edge explicitly.
    ref
      ..listen<SharingHealth>(sharingHealthProvider, (previous, next) {
        // The epoch outcome describes a fault. Once the fault is gone the
        // advice is about a problem the user no longer has, and this `State`
        // outlives the banner's disappearance (`build` returns
        // `SizedBox.shrink()`; it is not unmounted), so without this the next
        // unrelated fault would surface the previous incident's remedy.
        if (!next.isStopped) _clearStaleEpochOutcome();
        if (previous != null && previous.isStopped && !next.isStopped) {
          unawaited(
            SemanticsService.sendAnnouncement(
              View.of(context),
              l10n.sharingHealthResumedAnnouncement,
              Directionality.of(context),
            ),
          );
        }
      })
      // The widget is `const` with no per-circle key, so switching circles
      // keeps this `State` — and "this circle's admin" would then name the
      // wrong person's circle.
      ..listen<Circle?>(selectedCircleProvider, (previous, next) {
        if (previous?.mlsGroupId != next?.mlsGroupId) {
          _clearStaleEpochOutcome();
        }
      });

    final health = ref.watch(sharingHealthProvider);
    final copy = resolveSharingHealthCopy(
      health,
      l10n,
      ref.read(sharingHealthClockProvider)(),
    );
    _armRerender(armed: copy != null && _foreground.value);
    if (copy == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final epochMessage = _epochCopy(l10n, _epochOutcome, health);
    // A terminal outcome is one the user cannot change by pressing again.
    // Leaving Repair enabled under copy that says the circle cannot be repaired
    // here invites exactly the loop the classification exists to prevent.
    //
    // Gated on the copy having been EARNED, not on the outcome alone. The epoch
    // leg speaks only for a receive-side fault; against a send fault the same
    // outcome is silent, and killing the button there would leave a dead
    // control whose only explanation — "Repair is unavailable for this circle"
    // — describes a verdict the user was never shown, on a fault a ratchet
    // reset was never going to fix.
    final outcome = _epochOutcome;
    final repairIsFutile =
        epochMessage != null &&
        outcome is EpochRepairSkipped &&
        !outcome.isRetryable;

    return Card(
      key: WidgetKeys.sharingHealthBanner,
      margin: EdgeInsets.zero,
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Semantics(
                  // ONE node carrying the CAUSE and its remedy, so a screen
                  // reader speaks them as a single sentence rather than as
                  // orphaned fragments. `liveRegion` makes TalkBack/VoiceOver
                  // speak it the moment it appears without stealing focus
                  // (WCAG 2.1 SC 4.1.3 Status Messages).
                  container: true,
                  liveRegion: true,
                  // The age is deliberately NOT here. A `liveRegion`
                  // re-announces on every label change, and the age changes on
                  // every 72 s tick — so a fault that persisted for an hour was
                  // spoken over the user fifty times with nothing new to say.
                  // It lives in its own node below instead (WCAG 1.3.1: still
                  // programmatically determinable, just not shouted), and a
                  // resume with the fault still present gets ONE explicit
                  // announcement (`_announcePersistingFault`).
                  //
                  // The epoch outcome, by contrast, IS part of the status: it
                  // is often the remedy, it changes only when the user presses
                  // Repair, and its visual copy is excluded below. Changing
                  // this label re-announces it, which is why `_repair`
                  // deliberately does not also send one.
                  explicitChildNodes: true,
                  label: [
                    copy.title,
                    if (epochMessage != null) epochMessage,
                  ].join('\n'),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Decorative and unlabelled: the headline beside it
                      // carries the same meaning, so it contributes no node.
                      Icon(
                        LucideIcons.radioTower,
                        color: colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: HavenSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(
                              child: Text(
                                copy.title,
                                style: textTheme.titleSmall?.copyWith(
                                  color: colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                            const SizedBox(height: HavenSpacing.xs),
                            // Outside the exclusions on purpose: this is the
                            // one line the live label does not speak, so its
                            // own node is the only way a screen-reader user can
                            // read how long the fault has lasted.
                            Text(
                              copy.message,
                              style: textTheme.bodySmall?.copyWith(
                                color: colorScheme.onErrorContainer,
                              ),
                            ),
                            // What the epoch-repair leg answered, when it had
                            // something the user has to act on. Rendered in
                            // the banner rather than a snackbar: it is often
                            // a REMEDY ("ask the owner…"), and a message that
                            // disappears on its own is the wrong place for
                            // one.
                            if (epochMessage != null) ...[
                              const SizedBox(height: HavenSpacing.xs),
                              ExcludeSemantics(
                                child: Text(
                                  epochMessage,
                                  key: const Key(
                                    'sharing_health_epoch_repair_message',
                                  ),
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onErrorContainer,
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
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            // Deliberately OUTSIDE the status node: the remedy must stay its
            // own focusable, actionable element rather than being merged into
            // a block of prose.
            Align(
              alignment: AlignmentDirectional.centerEnd,
              // `MergeSemantics` is load-bearing, not decoration: `TextButton`
              // publishes its own container node, so an ancestor `Semantics`
              // hint would sit in a SEPARATE node the screen reader reads apart
              // from the button — or, in practice, never. Merging keeps one
              // focusable actionable element that carries both the label and
              // what activating it will do.
              child: MergeSemantics(
                child: Semantics(
                  // The label is the button's own text; the hint says what the
                  // action actually does, which "Repair" alone does not convey.
                  hint: repairIsFutile
                      ? l10n.sharingHealthRepairUnavailableHint
                      : l10n.sharingHealthRepairHint,
                  child: TextButton(
                    key: WidgetKeys.sharingHealthRepairButton,
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.onErrorContainer,
                      // The disabled label must stay legible: Material's
                      // default disabled foreground is the theme's onSurface at
                      // 38 %, which against `errorContainer` measured 2.5:1 —
                      // below WCAG 2.1 SC 1.4.3's 4.5:1. The container's own
                      // on-colour is the pair this surface was designed with.
                      disabledForegroundColor: colorScheme.onErrorContainer,
                    ),
                    onPressed: (_repairing || repairIsFutile) ? null : _repair,
                    // The label STAYS while the repair runs. Replacing it
                    // with a bare spinner left the control with no accessible
                    // name at all (WCAG 2.1 SC 4.1.2) for exactly the seconds
                    // a user is most likely to interrogate it, and left
                    // sighted users with a nameless disabled control where
                    // their button had been.
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
                        Flexible(child: Text(l10n.sharingHealthRepairAction)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
