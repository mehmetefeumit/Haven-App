/// The "this phone's clock is wrong" surface.
///
/// ## Why the user has to be told at all
///
/// A device with a skewed clock fails to share location in one of two ways,
/// and before this banner existed both were invisible. Ahead: every relay
/// refuses the event as being in its future, and the refusal died in a
/// `debugPrint`. Behind: the NIP-40 expiration is derived from the same skewed
/// clock, so the event is born already expired — the relay ACKs it, the
/// publisher **reports success**, and every peer discards it. Neither shows up
/// as an error anywhere the user can see, and neither resolves on its own.
///
/// A generic "location sharing is failing" would not help: the user cannot act
/// on it. Naming the clock is the whole point of the surface.
///
/// ## Why a banner and not a blocking dialog
///
/// The user's OWN sending being broken says nothing about their circles'
/// locations, which are still arriving and still worth looking at. Covering
/// the map would remove information the fault did not actually take away.
/// There is deliberately no dismiss affordance: a dismissible banner would let
/// the user hide a condition that is still true and still silently losing
/// their location updates.
///
/// ## No remedy button, on purpose
///
/// Android exposes a date-and-time settings intent; iOS has no deep link to
/// that screen at all. A button that works on one platform and silently does
/// nothing on the other is worse than no button, so the body carries the
/// instruction instead ("turn on automatic date and time in system settings"),
/// which is correct on both.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/clock_skew_provider.dart';
import 'package:haven/src/services/clock_skew_detector.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Title and body for one clock-skew verdict.
@immutable
class ClockSkewCopy {
  /// Creates a resolved copy bundle.
  const ClockSkewCopy({required this.title, required this.message});

  /// Short headline naming the blocker.
  final String title;

  /// Body explaining what stopped and how to restore it.
  final String message;
}

/// Maps a [ClockSkewStatus] to its user-facing copy.
///
/// Returns `null` for [ClockSkewSignal.none] — there is nothing to say. Pure,
/// so every branch is unit-testable without pumping a widget.
///
/// The two bodies say different things because the two faults are different
/// user experiences: with a relay rejection the user's location is going
/// nowhere at all, whereas with the peer signal it is being sent and quietly
/// discarded. Collapsing them into one sentence would make the second one a
/// lie in the direction that matters (it would imply the send itself failed).
///
/// The magnitude is deliberately NOT rendered. It is an estimate derived from
/// a handful of samples, and a precise-looking "your clock is 6 h 2 m slow" is
/// a claim the evidence does not support; the remedy ("turn on automatic date
/// and time") is identical at every magnitude anyway.
ClockSkewCopy? resolveClockSkewCopy(
  ClockSkewStatus status,
  AppLocalizations l10n,
) {
  switch (status.signal) {
    case ClockSkewSignal.none:
      return null;
    case ClockSkewSignal.relayRejectedTimestamp:
      return ClockSkewCopy(
        title: l10n.clockSkewTitle,
        message: l10n.clockSkewBodyRejected,
      );
    case ClockSkewSignal.peersAheadOfDevice:
      return ClockSkewCopy(
        title: l10n.clockSkewTitle,
        message: l10n.clockSkewBodyBehind,
      );
  }
}

/// Banner announcing that this device's clock is breaking location sharing.
///
/// Renders nothing while the clock looks fine, so it is safe to place
/// unconditionally in the map stack.
///
/// ## Height, and why the caller must bound it
///
/// Same shape as `LocationAccessBanner`: the card shrink-wraps, and at the
/// 200 % text scale both platforms offer, this body is taller than a small
/// phone's viewport. A `PositionedDirectional` with only a `top:` gives an
/// unbounded height, so the content would simply run off the bottom of the
/// screen — silently, since `RenderFlex` can only report an overflow it can
/// measure. The body therefore scrolls, which needs the caller to bound the
/// height; `MapShell` does that by giving the banner slot a `bottom:` as well
/// as a `top:`.
///
/// The scroll view sits OUTSIDE the status node deliberately: wrapping it the
/// other way would fold a scrollable's own semantics into the live region and
/// change what a screen reader announces.
class ClockSkewBanner extends ConsumerWidget {
  /// Creates the clock-skew banner.
  const ClockSkewBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    // A live region announces its APPEARANCE but never its removal, so a
    // screen-reader user would otherwise be told sharing is broken and never
    // told it recovered. Announce the recovery edge explicitly.
    ref.listen<ClockSkewStatus>(clockSkewProvider, (previous, next) {
      if (previous != null && previous.isSkewed && !next.isSkewed) {
        unawaited(
          SemanticsService.sendAnnouncement(
            View.of(context),
            l10n.clockSkewResolvedAnnouncement,
            Directionality.of(context),
          ),
        );
      }
    });

    final status = ref.watch(clockSkewProvider);
    final copy = resolveClockSkewCopy(status, l10n);
    if (copy == null) return const SizedBox.shrink();

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: SingleChildScrollView(
          child: Semantics(
            // ONE node carrying the whole status, so a screen reader speaks
            // cause and remedy as a single sentence rather than two orphaned
            // fragments the user must swipe between. `liveRegion` makes
            // TalkBack/VoiceOver speak it the moment it appears, without
            // stealing focus (WCAG 2.1 SC 4.1.3 Status Messages).
            //
            // The label is set explicitly and the visual subtree excluded: a
            // bare `container: true` around Text children leaves the container
            // node label-less, so the live region would fire with nothing to
            // say.
            container: true,
            liveRegion: true,
            label: '${copy.title}\n${copy.message}',
            child: ExcludeSemantics(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Decorative: the headline beside it carries the same
                  // meaning, so an unlabelled icon avoids a duplicate read.
                  Icon(
                    LucideIcons.clockAlert,
                    color: colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: HavenSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          copy.title,
                          style: textTheme.titleSmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: HavenSpacing.xs),
                        Text(
                          copy.message,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
