/// Invitation card widget for displaying pending circle invitations.
///
/// Shows invitation details with accept/decline actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';

/// A card widget that displays a pending circle invitation.
///
/// Shows invitation details including circle name, inviter pubkey,
/// member count, and time since invitation. Provides buttons to
/// accept or decline the invitation.
class InvitationCard extends ConsumerStatefulWidget {
  /// Creates an invitation card.
  const InvitationCard({required this.invitation, super.key});

  /// The invitation to display.
  final Invitation invitation;

  @override
  ConsumerState<InvitationCard> createState() => _InvitationCardState();
}

/// Which action the user triggered, for showing the correct loading spinner.
enum _LoadingAction { none, accepting, declining }

class _InvitationCardState extends ConsumerState<InvitationCard> {
  _LoadingAction _loadingAction = _LoadingAction.none;

  bool get _isLoading => _loadingAction != _LoadingAction.none;

  /// Stable, privacy-safe discriminator for this invitation's composite
  /// widget keys.
  ///
  /// E2E tests want stable `ValueKey`s so a scenario can target a
  /// specific invitation card when more than one is rendered. The
  /// previous implementation derived the key from
  /// `widget.invitation.mlsGroupId`, which embedded the real MLS group
  /// ID in the live widget tree — observable via the widget inspector,
  /// accessibility/semantics dumps, and `flutter test --reporter=json`
  /// artifacts. That violated CLAUDE.md rule #4 ("Only publish
  /// `nostr_group_id`, never real MLS group ID") at the on-device
  /// observability layer.
  ///
  /// The replacement combines the inviter's Nostr public key (which is
  /// already public — it's the `pubkey` field of every Nostr event the
  /// inviter ever sends) with the invitation's receive timestamp (which
  /// the relay also observes on the gift-wrap event). Both are derived
  /// strictly from public Nostr metadata; no MLS-side identifier touches
  /// the widget tree. The pair is unique per invitation in practice and
  /// stable across rebuilds for the lifetime of the card.
  String get _keyDiscriminator =>
      '${widget.invitation.inviterPubkey}_'
      '${widget.invitation.invitedAt.millisecondsSinceEpoch}';

  /// Formats a timestamp as a human-readable time ago string.
  String _formatTimeAgo(AppLocalizations l10n, DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return l10n.invitationCardDaysAgo(difference.inDays);
    } else if (difference.inHours > 0) {
      return l10n.invitationCardHoursAgo(difference.inHours);
    } else if (difference.inMinutes > 0) {
      return l10n.invitationCardMinutesAgo(difference.inMinutes);
    } else {
      return l10n.invitationCardJustNow;
    }
  }

  /// Truncates a pubkey to show first 8 and last 4 hex characters.
  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) {
      return pubkey;
    }
    return '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 4)}';
  }

  /// Handles accepting the invitation.
  Future<void> _handleAccept() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _loadingAction = _LoadingAction.accepting;
    });

    try {
      debugPrint('[Accept] starting acceptInvitation');
      final circleService = ref.read(circleServiceProvider);
      final acceptedCircle = await circleService.acceptInvitation(
        widget.invitation.mlsGroupId,
      );
      debugPrint(
        '[Accept] acceptInvitation OK '
        '(members=${acceptedCircle.members.length}, '
        'relays=${acceptedCircle.relays.length})',
      );

      // Auto-select the accepted circle so the map immediately shows
      // member locations without requiring a manual tap.
      ref.read(selectedCircleIdProvider.notifier).state =
          acceptedCircle.mlsGroupId;

      // Invalidate providers to refresh UI and republish a fresh KeyPackage.
      // read() after invalidate() triggers execution for fire-and-forget
      // providers that nothing watches.
      debugPrint('[Accept] triggering keyPackagePublisher + locationPublisher');
      ref
        ..invalidate(pendingInvitationsProvider)
        ..invalidate(circlesProvider)
        ..invalidate(keyPackagePublisherProvider)
        ..read(keyPackagePublisherProvider)
        ..invalidate(locationPublisherProvider)
        ..read(locationPublisherProvider)
        ..invalidate(memberLocationsProvider);

      // Kick off the joiner-side burst-poll window so existing members'
      // locations land within seconds. Self-terminates after a jittered
      // 50–80 s window.
      debugPrint('[Accept] starting joiner burst watcher');
      ref
          .read(joinWatcherProvider.notifier)
          .startJoinerWatch(acceptedCircle.mlsGroupId);

      // Post-welcome self-update is intentionally NOT issued here.
      //
      // As of M5, periodic + post-join self-update is disabled entirely
      // (`enablePeriodicSelfUpdate = false`) because leaderless self-update
      // is the dominant MLS fork generator — there is no rotation to
      // delegate to (the MIP-02 deviation is documented/accepted in
      // SECURITY.md). Historical reasons it was never issued inline anyway:
      //
      // 1. Single-joiner race: an immediate `selfUpdate` here advances
      //    the joiner's local epoch to N+1 while the just-fired
      //    `locationPublisher` is still racing to encrypt at epoch N.
      //    If `selfUpdate` finalizes first, the location is encrypted
      //    at N+1, but the admin is still at N — admin returns
      //    `Unprocessable`, the `since` cursor advances, and the first
      //    location event is lost permanently.
      //
      // 2. Multi-joiner fork: when several invitees accept within
      //    seconds, each independently creates a commit at the same
      //    epoch. MLS allows only one commit per epoch; the losers'
      //    commits become `Unprocessable` for everyone else while the
      //    losers' own MDK has already finalized them locally. The
      //    losers are silently forked off the group.
      //
      // M5 removes the periodic/post-join self-update driver entirely, so
      // both failure modes above are moot (there is simply no self-update
      // to race or fork). Concurrent MEMBERSHIP commits remain a residual
      // fork risk until M3 wires the M4 adopt-winner convergence primitive
      // into the commit paths (see SECURITY.md "Residual fork surface").
      //
      // White Noise reached the same conclusion — see
      // `whitenoise-rs/src/whitenoise/event_processor/event_handlers/
      // handle_giftwrap.rs` finalize_welcome_with_instance, where the
      // post-welcome `perform_self_update` call is commented out with
      // the same motivation.

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.invitationAcceptedSnack)));
      }
    } on Object catch (e) {
      // Catch all throwables including FFI errors (which throw Error, not
      // Exception). Secret details are logged via debugPrint (stripped in
      // release) while the user sees a generic message.
      debugPrint('Failed to accept invitation: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.invitationAcceptError),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingAction = _LoadingAction.none;
        });
      }
    }
  }

  /// Handles declining the invitation.
  Future<void> _handleDecline() async {
    final l10n = AppLocalizations.of(context);
    setState(() {
      _loadingAction = _LoadingAction.declining;
    });

    try {
      final circleService = ref.read(circleServiceProvider);
      await circleService.declineInvitation(widget.invitation.mlsGroupId);

      // Invalidate provider to refresh UI
      ref.invalidate(pendingInvitationsProvider);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.invitationDeclinedSnack)));
      }
      // Catch all throwables including FFI errors.
    } on Object catch (e) {
      debugPrint('Failed to decline invitation: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.invitationDeclineError),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _loadingAction = _LoadingAction.none;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final circleName = widget.invitation.circleName;

    return Semantics(
      label: l10n.invitationCardSemantics(
        circleName,
        _truncatePubkey(widget.invitation.inviterPubkey),
        widget.invitation.memberCount,
      ),
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.sm,
        ),
        child: Padding(
          padding: const EdgeInsets.all(HavenSpacing.base),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Circle name
              Text(
                circleName,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: HavenSpacing.sm),

              // Inviter pubkey
              Semantics(
                label: l10n.invitationCardInvitedBySemantics(
                  _truncatePubkey(widget.invitation.inviterPubkey),
                ),
                child: Text(
                  l10n.invitationCardInvitedBy(
                    _truncatePubkey(widget.invitation.inviterPubkey),
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: HavenSpacing.xs),

              // Member count
              Text(
                l10n.invitationCardMemberCount(widget.invitation.memberCount),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: HavenSpacing.xs),

              // Time ago
              Text(
                _formatTimeAgo(l10n, widget.invitation.invitedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: HavenSpacing.md),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Decline button
                  OutlinedButton(
                    key: WidgetKeys.invitationDecline(_keyDiscriminator),
                    onPressed: _isLoading ? null : _handleDecline,
                    child: _loadingAction == _LoadingAction.declining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l10n.invitationCardDecline),
                  ),
                  const SizedBox(width: HavenSpacing.sm),

                  // Accept button
                  FilledButton(
                    key: WidgetKeys.invitationAccept(_keyDiscriminator),
                    onPressed: _isLoading ? null : _handleAccept,
                    child: _loadingAction == _LoadingAction.accepting
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : Text(l10n.invitationCardAccept),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
