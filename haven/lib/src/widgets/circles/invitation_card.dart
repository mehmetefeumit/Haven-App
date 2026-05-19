/// Invitation card widget for displaying pending circle invitations.
///
/// Shows invitation details with accept/decline actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/invitation_provider.dart';
import 'package:haven/src/providers/join_watcher_provider.dart';
import 'package:haven/src/providers/key_package_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/security/encryption_badge.dart';

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

  /// Formats a timestamp as a human-readable time ago string.
  String _formatTimeAgo(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
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
      // Forward-secrecy rotation (MIP-02 SHOULD within 24h) is delegated
      // entirely to the hourly `selfUpdateProvider` in `map_shell.dart`.
      // Reasons:
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
      // The hourly retry path naturally serialises (per-device, on a
      // jittered cadence) and runs only when MDK reports the post-join
      // rotation as still outstanding, so both failure modes vanish
      // without affecting the steady-state forward-secrecy property.
      //
      // White Noise reached the same conclusion — see
      // `whitenoise-rs/src/whitenoise/event_processor/event_handlers/
      // handle_giftwrap.rs` finalize_welcome_with_instance, where the
      // post-welcome `perform_self_update` call is commented out with
      // the same motivation.

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invitation accepted')));
      }
    } on Object catch (e) {
      // Catch all throwables including FFI errors (which throw Error, not
      // Exception). Secret details are logged via debugPrint (stripped in
      // release) while the user sees a generic message.
      debugPrint('Failed to accept invitation: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Failed to accept invitation. Please try again.',
            ),
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
        ).showSnackBar(const SnackBar(content: Text('Invitation declined')));
      }
      // Catch all throwables including FFI errors.
    } on Object catch (e) {
      debugPrint('Failed to decline invitation: ${e.runtimeType}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Failed to decline invitation. Please try again.',
            ),
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
    final theme = Theme.of(context);
    final circleName = widget.invitation.circleName;

    return Semantics(
      label:
          'Invitation to join $circleName, '
          'invited by ${_truncatePubkey(widget.invitation.inviterPubkey)}, '
          '${widget.invitation.memberCount} members',
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
                label:
                    'Invited by cryptographic identifier '
                    '${_truncatePubkey(widget.invitation.inviterPubkey)}',
                child: Text(
                  'Invited by: '
                  '${_truncatePubkey(widget.invitation.inviterPubkey)}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(height: HavenSpacing.xs),

              // Member count
              Text(
                '${widget.invitation.memberCount} '
                '${widget.invitation.memberCount == 1 ? 'member' : 'members'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: HavenSpacing.xs),

              // Time ago
              Text(
                _formatTimeAgo(widget.invitation.invitedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: HavenSpacing.md),

              // Encrypted indicator
              const EncryptionBadge(size: EncryptionBadgeSize.small),
              const SizedBox(height: HavenSpacing.md),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Decline button
                  OutlinedButton(
                    onPressed: _isLoading ? null : _handleDecline,
                    child: _loadingAction == _LoadingAction.declining
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Decline'),
                  ),
                  const SizedBox(width: HavenSpacing.sm),

                  // Accept button
                  FilledButton(
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
                        : const Text('Accept'),
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
