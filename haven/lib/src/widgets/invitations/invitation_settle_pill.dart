/// The "Settle Pill" — minimalist refresh feedback for the Invitations page.
///
/// A single small pill slides in under the app bar when the user refreshes,
/// shows a calm "Checking your inbox…", then morphs in place to a one-line
/// result (e.g. "All answered · nothing new" or "2 new invitations"). Calm
/// results auto-hide after a few seconds; problems (some relays unreachable,
/// or no inbox configured) stay put with a tap action so they aren't missed.
///
/// It never shows a count while in flight, so it can never display a
/// misleading interim number — the only integers it shows are final and exact
/// (see [InvitationPollStatusNotifier]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/invitation_poll_status_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Matches the app's standard state-swap animation (display_name_card).
const _kMorphDuration = Duration(milliseconds: 200);

/// How long a calm result lingers before auto-hiding.
const _kHoldDuration = Duration(seconds: 3);

/// Fixed height reserved for the pill band. The pill fades in and out within
/// this space (vertically centred) so the list below never reflows.
const _kPillBandHeight = 52.0;

/// Inbox-refresh feedback pill shown under the Invitations app bar.
class InvitationSettlePill extends ConsumerStatefulWidget {
  /// Creates an [InvitationSettlePill].
  const InvitationSettlePill({super.key, this.onConfigureInbox});

  /// Called when the user taps "Set up" in the no-inbox state. When null,
  /// the no-inbox pill shows no action.
  final VoidCallback? onConfigureInbox;

  @override
  ConsumerState<InvitationSettlePill> createState() =>
      _InvitationSettlePillState();
}

class _InvitationSettlePillState extends ConsumerState<InvitationSettlePill> {
  Timer? _hideTimer;

  /// Set once the auto-hide timer fires for a calm result, hiding the pill
  /// until the next refresh. Sticky results (partial/offline/no-inbox) never
  /// set this, so they remain visible.
  bool _hiddenAfterSettle = false;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _onStatusChanged(
    InvitationPollStatus? previous,
    InvitationPollStatus next,
  ) {
    _hideTimer?.cancel();
    final l10n = AppLocalizations.of(context);
    // A new status always re-shows the pill. setState (rather than a bare
    // assignment) makes visibility independent of listener/rebuild ordering;
    // ref.listen callbacks fire outside build, so this is safe.
    if (_hiddenAfterSettle) setState(() => _hiddenAfterSettle = false);

    switch (next.phase) {
      case InvitationPollPhase.idle:
        break;
      case InvitationPollPhase.checking:
        _announce(l10n.invitationPillCheckingAnnouncement);
      case InvitationPollPhase.settled:
        _announce(_announcementFor(l10n, next));
        if (!_isSticky(next.outcome)) {
          _hideTimer = Timer(_kHoldDuration, () {
            if (mounted) setState(() => _hiddenAfterSettle = true);
          });
        }
    }
  }

  /// Whether a settled outcome should stay until the next refresh.
  bool _isSticky(InvitationPollOutcome? outcome) => switch (outcome) {
    InvitationPollOutcome.partial ||
    InvitationPollOutcome.offline ||
    InvitationPollOutcome.noInbox => true,
    _ => false,
  };

  void _announce(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        // Announce in the active locale's direction (RTL for ar/he/fa).
        Directionality.of(context),
      );
    });
  }

  void _retry() {
    unawaited(ref.read(invitationPollStatusProvider.notifier).refresh());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<InvitationPollStatus>(
      invitationPollStatusProvider,
      _onStatusChanged,
    );
    final status = ref.watch(invitationPollStatusProvider);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final visible =
        status.phase != InvitationPollPhase.idle && !_hiddenAfterSettle;

    // The pill lives in a fixed-height band that is always reserved, so the
    // list below never reflows. Showing/hiding and morphing between states are
    // both a cross-fade within the band — the pill never pushes anything down.
    return SizedBox(
      height: _kPillBandHeight,
      width: double.infinity,
      child: AnimatedSwitcher(
        duration: reducedMotion ? Duration.zero : _kMorphDuration,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) =>
            FadeTransition(opacity: animation, child: child),
        child: KeyedSubtree(
          key: ValueKey<String>(visible ? _visualKey(status) : 'hidden'),
          child: visible
              ? _buildPillContent(context, status, reducedMotion)
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildPillContent(
    BuildContext context,
    InvitationPollStatus status,
    bool reducedMotion,
  ) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final visual = _visualFor(l10n, status, scheme);
    final maxWidth = MediaQuery.sizeOf(context).width - HavenSpacing.base * 2;

    final inner = Container(
      key: WidgetKeys.invitationsSettlePill,
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.base,
        vertical: HavenSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: visual.color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Leading(visual: visual, reducedMotion: reducedMotion),
          const SizedBox(width: HavenSpacing.sm),
          Flexible(
            child: Text(
              visual.label,
              overflow: TextOverflow.ellipsis,
              // Semantic colour lives on the icon + tinted background; the
              // text itself stays high-contrast (onSurface) so it clears
              // WCAG AA at 14px, where the accent hues do not.
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: scheme.onSurface),
            ),
          ),
          if (visual.action != null) ...[
            const SizedBox(width: HavenSpacing.sm),
            Text(
              visual.action!.label,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: scheme.onSurface,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ],
      ),
    );

    final tappable = visual.action != null
        ? Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: visual.action!.onTap,
              child: inner,
            ),
          )
        : inner;

    final content = Semantics(
      container: true,
      button: visual.action != null,
      label: _announcementFor(l10n, status),
      onTap: visual.action?.onTap,
      onTapHint: visual.action?.label,
      child: ExcludeSemantics(child: tappable),
    );

    // Horizontal inset only; the fixed band centers the pill vertically.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.base),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: content,
        ),
      ),
    );
  }

  /// A stable key for the current visual state, so the morph cross-fades only
  /// when the content actually changes.
  String _visualKey(InvitationPollStatus status) =>
      status.phase == InvitationPollPhase.settled
      ? 'settled:${status.outcome}:${status.responded}/${status.total}:${status.newCount}'
      : status.phase.name;

  _PillVisual _visualFor(
    AppLocalizations l10n,
    InvitationPollStatus status,
    ColorScheme scheme,
  ) {
    if (status.phase == InvitationPollPhase.checking) {
      return _PillVisual(
        color: scheme.onSurfaceVariant,
        label: l10n.invitationPillChecking,
        showSpinner: true,
      );
    }

    switch (status.outcome) {
      case InvitationPollOutcome.newInvites:
        return _PillVisual(
          color: HavenSecurityColors.encrypted,
          icon: LucideIcons.mailPlus,
          label: l10n.invitationPillNewCount(status.newCount),
        );
      case InvitationPollOutcome.upToDate:
        return _PillVisual(
          color: HavenSecurityColors.encrypted,
          icon: LucideIcons.circleCheck,
          label: l10n.invitationPillUpToDate,
        );
      case InvitationPollOutcome.partial:
        return _PillVisual(
          color: HavenSecurityColors.warning,
          icon: LucideIcons.circleAlert,
          label: l10n.invitationPillPartial(status.responded, status.total),
          action: _PillAction(label: l10n.commonRetry, onTap: _retry),
        );
      case InvitationPollOutcome.offline:
        return _PillVisual(
          color: HavenSecurityColors.danger,
          icon: LucideIcons.cloudOff,
          label: l10n.invitationPillOffline,
          action: _PillAction(label: l10n.commonRetry, onTap: _retry),
        );
      case InvitationPollOutcome.noInbox:
        return _PillVisual(
          color: scheme.onSurfaceVariant,
          icon: LucideIcons.inbox,
          label: l10n.invitationPillNoInbox,
          action: widget.onConfigureInbox == null
              ? null
              : _PillAction(
                  label: l10n.invitationPillSetUp,
                  onTap: widget.onConfigureInbox!,
                ),
        );
      case null:
        // Settled with no outcome should not occur; fail calm.
        return _PillVisual(
          color: scheme.onSurfaceVariant,
          icon: LucideIcons.circleCheck,
          label: l10n.invitationPillDone,
        );
    }
  }

  /// The screen-reader sentence for a status (fuller than the visual label).
  String _announcementFor(AppLocalizations l10n, InvitationPollStatus status) {
    if (status.phase == InvitationPollPhase.checking) {
      return l10n.invitationPillCheckingAnnouncement;
    }
    return switch (status.outcome) {
      InvitationPollOutcome.newInvites => l10n.invitationPillNewCount(
        status.newCount,
      ),
      InvitationPollOutcome.upToDate => l10n.invitationPillUpToDateAnnouncement,
      InvitationPollOutcome.partial => l10n.invitationPillPartial(
        status.responded,
        status.total,
      ),
      InvitationPollOutcome.offline => l10n.invitationPillOfflineAnnouncement,
      InvitationPollOutcome.noInbox => l10n.invitationPillNoInbox,
      null => l10n.invitationPillDone,
    };
  }
}

/// The leading element of the pill: a spinner while checking, else an icon.
class _Leading extends StatelessWidget {
  const _Leading({required this.visual, required this.reducedMotion});

  final _PillVisual visual;
  final bool reducedMotion;

  @override
  Widget build(BuildContext context) {
    if (visual.showSpinner) {
      // A static dot under reduced motion; a small spinner otherwise.
      return SizedBox(
        width: 16,
        height: 16,
        child: reducedMotion
            ? Icon(LucideIcons.loaderCircle, size: 16, color: visual.color)
            : CircularProgressIndicator(strokeWidth: 2, color: visual.color),
      );
    }
    return Icon(visual.icon, size: 16, color: visual.color);
  }
}

/// Immutable visual description of one pill state.
@immutable
class _PillVisual {
  const _PillVisual({
    required this.color,
    required this.label,
    this.icon,
    this.showSpinner = false,
    this.action,
  });

  final Color color;
  final String label;
  final IconData? icon;
  final bool showSpinner;
  final _PillAction? action;
}

/// A tap action shown inside the pill (Retry / Set up).
@immutable
class _PillAction {
  const _PillAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;
}
