/// Tile displaying a circle member with status.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// Displays a circle member with their status and actions.
///
/// When [member] is the current user, the title and avatar use the display
/// name saved in settings (via `IdentityService.setDisplayName`) rather
/// than the pubkey hex. See [resolveMemberDisplayName].
///
/// When [hasLocation] is `false` the tile is rendered in a disabled
/// Material state and [onTap] is ignored, so a user can see at a glance
/// which members can be centered on the map. Accepted members with no
/// cached location display a "No recent location" hint; pending invitees
/// keep the existing "Invitation Pending" status.
class CircleMemberTile extends ConsumerWidget {
  /// Creates a [CircleMemberTile].
  const CircleMemberTile({
    required this.member,
    this.onTap,
    this.trailing,
    this.hasLocation = true,
    this.onRemove,
    this.isLeaving = false,
    super.key,
  });

  /// The member to display.
  final CircleMember member;

  /// Callback when the tile is tapped.
  ///
  /// Ignored when [hasLocation] is `false` or the member is pending.
  final VoidCallback? onTap;

  /// Optional trailing widget (e.g., remove button). When provided, it
  /// overrides the default focus-locator affordance that tappable tiles
  /// render.
  final Widget? trailing;

  /// Whether a last-known location is available for this member.
  ///
  /// Defaults to `true` to preserve the widget's original behaviour when
  /// used outside the map-centric context.
  final bool hasLocation;

  /// When non-null, renders an admin "Remove member" action in the
  /// trailing area. Set by the parent only when the viewer is an admin
  /// and it is safe for them to evict this member — most commonly the
  /// ghost-admin case (see `docs/ADMIN_LEAVE_GHOST_BUG.md`) where an
  /// admin's SelfRemove was silently dropped by MDK and the only way to
  /// finalize the departure is an admin-published RemoveMember commit.
  ///
  /// Ignored when [trailing] is provided (explicit override wins).
  final VoidCallback? onRemove;

  /// Renders a "Leaving…" hint on the member row.
  ///
  /// Set by the parent when [onRemove] is offered due to a ghost-admin
  /// pending-departure signal, so the user understands *why* the
  /// Remove affordance appeared on this specific row.
  final bool isLeaving;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    // While either provider is still loading we treat the value as null and
    // fall back to the Contact-table name / truncated pubkey — exactly how
    // the tile behaved before self-awareness was added.
    final currentUserPubkey = ref
        .watch(identityProvider)
        .valueOrNull
        ?.pubkeyHex;
    final currentUserDisplayName = ref.watch(displayNameProvider).valueOrNull;

    final effectiveDisplayName = resolveMemberDisplayName(
      member,
      currentUserPubkey: currentUserPubkey,
      currentUserDisplayName: currentUserDisplayName,
    );

    final isPending = member.status == MembershipStatus.pending;
    final isInteractive = onTap != null && !isPending && hasLocation;

    final displayedName =
        effectiveDisplayName ?? NpubValidator.truncate(member.pubkey);
    final semanticHint = _semanticsHint(
      isPending: isPending,
      hasLocation: hasLocation,
      isInteractive: isInteractive,
    );

    // Keep the ListTile visually enabled even when non-interactive: the
    // "disabled" state dims the title and avatar, which obscures the
    // member's identity for a condition ("no recent location") that is a
    // *data* state rather than an action being unavailable. Interaction
    // gating is done via `onTap: null`, and semantics are overridden
    // above so screen readers still hear the row as non-actionable.
    //
    // When an interactive child (e.g. the Remove button) is present, do
    // not exclude descendant semantics — otherwise the IconButton's
    // tooltip/label would be swallowed and the button would be
    // invisible to TalkBack/VoiceOver. The row label still reads first
    // thanks to standard traversal order.
    final hasInteractiveChild = onRemove != null;
    return Semantics(
      button: isInteractive,
      enabled: isInteractive,
      label: '$displayedName, $semanticHint',
      excludeSemantics: !hasInteractiveChild,
      child: ListTile(
        leading: _MemberAvatar(
          pubkey: member.pubkey,
          displayName: effectiveDisplayName,
        ),
        title: Text(
          displayedName,
          style: effectiveDisplayName == null
              ? HavenTypography.mono.copyWith(fontSize: 14)
              : null,
        ),
        subtitle: _buildSubtitle(context, colorScheme, effectiveDisplayName),
        trailing:
            trailing ??
            _buildTrailing(
              context: context,
              isPending: isPending,
              isInteractive: isInteractive,
            ),
        onTap: isInteractive ? onTap : null,
      ),
    );
  }

  Widget? _buildSubtitle(
    BuildContext context,
    ColorScheme colorScheme,
    String? effectiveDisplayName,
  ) {
    if (member.status == MembershipStatus.pending) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 14, color: HavenSecurityColors.warning),
          const SizedBox(width: HavenSpacing.xs),
          Text(
            'Invitation Pending',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: HavenSecurityColors.warning),
          ),
        ],
      );
    }

    if (isLeaving) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.logout, size: 14, color: HavenSecurityColors.warning),
          const SizedBox(width: HavenSpacing.xs),
          Text(
            'Leaving…',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: HavenSecurityColors.warning),
          ),
        ],
      );
    }

    if (!hasLocation) {
      return Text(
        'No recent location',
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
      );
    }

    if (effectiveDisplayName != null) {
      // Show truncated pubkey as subtitle when we have a display name
      return Text(
        NpubValidator.truncate(member.pubkey, prefixLength: 8, suffixLength: 4),
        style: HavenTypography.monoSmall.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    return null;
  }

  Widget? _buildTrailing({
    required BuildContext context,
    required bool isPending,
    required bool isInteractive,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    final locator = isInteractive
        ? Icon(Icons.my_location, size: 20, color: colorScheme.primary)
        : null;

    final removeButton = onRemove == null
        ? null
        : IconButton(
            icon: Icon(
              Icons.person_remove_outlined,
              size: 22,
              color: HavenSecurityColors.warning,
            ),
            onPressed: onRemove,
            tooltip: 'Remove from circle',
            visualDensity: VisualDensity.compact,
          );

    // Admins are the most commonly-focused members; rendering the chip
    // alongside the locator icon preserves the tap-to-center affordance
    // while keeping the admin badge visible.
    if (member.isAdmin) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locator != null) ...[
            locator,
            const SizedBox(width: HavenSpacing.xs),
          ],
          const Chip(
            label: Text('Admin'),
            labelStyle: TextStyle(fontSize: 11),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
          ),
          if (removeButton != null) ...[
            const SizedBox(width: HavenSpacing.xs),
            removeButton,
          ],
        ],
      );
    }

    if (removeButton != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (locator != null) ...[
            locator,
            const SizedBox(width: HavenSpacing.xs),
          ],
          removeButton,
        ],
      );
    }

    return locator;
  }

  String _semanticsHint({
    required bool isPending,
    required bool hasLocation,
    required bool isInteractive,
  }) {
    if (isPending) return 'invitation pending';
    if (!hasLocation) return 'no location available';
    if (!isInteractive) return 'member';
    return 'tap to center map on their location';
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.pubkey, this.displayName});

  final String pubkey;
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    // Generate a color from the pubkey for visual distinction
    final colorIndex = pubkey.hashCode.abs() % Colors.primaries.length;
    final avatarColor = Colors.primaries[colorIndex];

    final initial = _initialFor(displayName, pubkey);

    return CircleAvatar(
      backgroundColor: avatarColor.withValues(alpha: 0.2),
      foregroundColor: avatarColor,
      child: Text(
        initial,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: avatarColor.shade700,
        ),
      ),
    );
  }

  // The FFI today always delivers a 64-char lowercase hex pubkey, but we
  // don't want a malformed record (short pubkey + no display name) to crash
  // the whole member list. Pick a deterministic fallback glyph instead.
  static String _initialFor(String? displayName, String pubkey) {
    final name = displayName;
    if (name != null && name.isNotEmpty) {
      return name.characters.first.toUpperCase();
    }
    if (pubkey.length > 5) {
      return pubkey[5].toUpperCase();
    }
    if (pubkey.isNotEmpty) {
      return pubkey.characters.first.toUpperCase();
    }
    return '?';
  }
}

/// A tile for displaying a pending member being added to a circle.
///
/// Shows validation status (loading, valid, error) while KeyPackage is fetched.
class PendingMemberTile extends StatelessWidget {
  /// Creates a [PendingMemberTile].
  const PendingMemberTile({
    required this.npub,
    required this.status,
    this.errorMessage,
    this.onRemove,
    this.onRetry,
    super.key,
  });

  /// The npub of the member.
  final String npub;

  /// Current validation status.
  final ValidationStatus status;

  /// Error message if validation failed.
  final String? errorMessage;

  /// Callback when remove button is pressed.
  final VoidCallback? onRemove;

  /// Callback when retry button is pressed (for network failures).
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: _buildLeadingIcon(colorScheme),
      title: Text(
        NpubValidator.truncate(npub),
        style: HavenTypography.mono.copyWith(fontSize: 14),
      ),
      subtitle: _buildSubtitle(context),
      trailing: _buildTrailing(),
    );
  }

  Widget? _buildTrailing() {
    if (onRemove == null && onRetry == null) return null;

    // Show retry + close for retryable failures
    if (status == ValidationStatus.invalid && onRetry != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: onRetry,
            tooltip: 'Retry validation',
          ),
          if (onRemove != null) ...[
            const SizedBox(width: HavenSpacing.xs),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: onRemove,
              tooltip: 'Remove member',
            ),
          ],
        ],
      );
    }

    // Default: just close button
    if (onRemove != null) {
      return IconButton(
        icon: const Icon(Icons.close),
        onPressed: onRemove,
        tooltip: 'Remove member',
      );
    }

    return null;
  }

  Widget _buildLeadingIcon(ColorScheme colorScheme) {
    return switch (status) {
      ValidationStatus.validating => Semantics(
        label: 'Validating',
        child: SizedBox(
          width: 40,
          height: 40,
          child: Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colorScheme.primary,
              ),
            ),
          ),
        ),
      ),
      ValidationStatus.valid => CircleAvatar(
        backgroundColor: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
        child: Icon(
          Icons.check_circle,
          color: HavenSecurityColors.encrypted,
          semanticLabel: 'Valid',
        ),
      ),
      ValidationStatus.invalid => CircleAvatar(
        backgroundColor: HavenSecurityColors.warning.withValues(alpha: 0.1),
        child: Icon(
          Icons.warning_amber,
          color: HavenSecurityColors.warning,
          semanticLabel: 'Warning',
        ),
      ),
    };
  }

  Widget? _buildSubtitle(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodySmall;

    return switch (status) {
      ValidationStatus.validating => Text(
        'Checking availability...',
        style: textStyle?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      ValidationStatus.valid => Text(
        'Ready to invite',
        style: textStyle?.copyWith(color: HavenSecurityColors.encrypted),
      ),
      ValidationStatus.invalid => Text(
        errorMessage ?? 'No Haven account found',
        style: textStyle?.copyWith(color: HavenSecurityColors.warning),
      ),
    };
  }
}

/// Validation status for a pending member.
enum ValidationStatus {
  /// Currently validating (fetching KeyPackage).
  validating,

  /// Validation successful (KeyPackage found).
  valid,

  /// Validation failed (no KeyPackage found).
  invalid,
}
