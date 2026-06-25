/// Tile displaying a circle member with status.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/member_avatar_provider.dart';
import 'package:haven/src/providers/own_avatar_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/member_display.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/identity/avatar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
///
/// When [mlsGroupId] is provided, the avatar area shows the member's
/// received encrypted avatar (M2) via [memberAvatarThumbnailProvider],
/// falling back to the initials-based [CircleAvatar] when null or on error.
class CircleMemberTile extends ConsumerWidget {
  /// Creates a [CircleMemberTile].
  const CircleMemberTile({
    required this.member,
    this.onTap,
    this.trailing,
    this.hasLocation = true,
    this.onRemove,
    this.mlsGroupId,
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
  /// trailing area. Set by the parent when the viewer is an admin and
  /// it is safe for them to evict this member.
  ///
  /// Ignored when [trailing] is provided (explicit override wins).
  final VoidCallback? onRemove;

  /// MLS group ID for the circle this member belongs to.
  ///
  /// When provided, the avatar area watches [memberAvatarThumbnailProvider]
  /// and renders the member's received encrypted thumbnail via [HavenAvatar].
  /// When null, falls back to the initials-only [CircleAvatar].
  final List<int>? mlsGroupId;

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

    // The current user's own avatar lives in the OWN-avatar store (keyed only
    // by pubkey), NOT the received-member store the other tiles read from. When
    // this tile is the viewer's own row we must source the thumbnail from
    // ownAvatarProvider instead, otherwise the user never sees their own
    // profile picture in the member list. See [_MemberAvatar].
    final isSelf = isSelfMember(member, currentUserPubkey: currentUserPubkey);

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
          mlsGroupId: mlsGroupId,
          isCurrentUser: isSelf,
        ),
        title: Text(
          displayedName,
          style: effectiveDisplayName == null
              ? HavenTypography.mono.copyWith(fontSize: 14)
              : null,
        ),
        subtitle: _buildSubtitle(context, colorScheme, effectiveDisplayName),
        trailing: trailing ?? _buildTrailing(),
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
          const Icon(LucideIcons.clock, size: 14, color: HavenSecurityColors.warning),
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
        NpubValidator.truncate(member.pubkey, prefixLength: 8),
        style: HavenTypography.monoSmall.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    return null;
  }

  Widget? _buildTrailing() {
    final removeButton = onRemove == null
        ? null
        : IconButton(
            icon: const Icon(
              LucideIcons.userMinus,
              size: 22,
              color: HavenSecurityColors.warning,
            ),
            onPressed: onRemove,
            tooltip: 'Remove from circle',
            visualDensity: VisualDensity.compact,
          );

    if (member.isAdmin) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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

    return removeButton;
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

/// Avatar widget for a circle member.
///
/// When [mlsGroupId] is provided, watches [memberAvatarThumbnailProvider]
/// and renders the member's received encrypted thumbnail via [HavenAvatar]
/// when bytes are available. Falls back to an initials-based [CircleAvatar]
/// when bytes are null, the provider is loading, or an error occurs.
/// No shimmer is shown during loading — that would leak "avatar incoming"
/// to a bystander observing the UI.
///
/// When [mlsGroupId] is null, always renders the initials fallback.
///
/// When [isCurrentUser] is `true`, the thumbnail is sourced from
/// [ownAvatarProvider] (the OWN-avatar store) rather than
/// [memberAvatarThumbnailProvider] (the received-member store). The viewer's
/// own avatar is never broadcast back to themselves, so it only ever exists in
/// the own store; reading the member store for self would always miss. Sourcing
/// from [ownAvatarProvider] also means the row refreshes the instant the user
/// sets or clears their picture in settings (that controller invalidates it).
class _MemberAvatar extends ConsumerWidget {
  const _MemberAvatar({
    required this.pubkey,
    this.displayName,
    this.mlsGroupId,
    this.isCurrentUser = false,
  });

  final String pubkey;
  final String? displayName;

  /// MLS group ID bytes; when non-null, enables avatar thumbnail loading.
  final List<int>? mlsGroupId;

  /// Whether this tile represents the current user (the viewer).
  ///
  /// When `true`, the avatar is read from [ownAvatarProvider] instead of the
  /// per-circle received-member store.
  final bool isCurrentUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;
    // Desaturated HSL hue derived from the pubkey gives each member a stable
    // tint without the brand-blue/red collisions of Colors.primaries.
    final hue = (pubkey.hashCode.abs() % 360).toDouble();
    final tint = HSLColor.fromAHSL(1, hue, 0.30, 0.55).toColor();

    final initial = _initialFor(displayName, pubkey);

    // Build the initials fallback once; reused by both branches.
    final initialsAvatar = CircleAvatar(
      backgroundColor: tint.withValues(alpha: 0.18),
      foregroundColor: colorScheme.onSurface,
      child: Text(
        initial,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          color: colorScheme.onSurface,
        ),
      ),
    );

    final groupId = mlsGroupId;
    // A non-self member with no circle context has no store to query.
    if (!isCurrentUser && groupId == null) {
      return initialsAvatar;
    }

    // Resolve the thumbnail bytes from the correct store:
    // - self: the own-avatar store (ownAvatarProvider), keyed by pubkey only.
    //   Invalidated by OwnAvatarController on set/clear, so this row refreshes
    //   the instant the user changes their picture in settings.
    // - others: the per-circle received-member store, keyed by (group, pubkey).
    // Both providers are autoDispose — released when the tile leaves the tree.
    // The `groupId!` is safe: when !isCurrentUser we passed the guard above, so
    // groupId is non-null; when isCurrentUser the ternary never reads it.
    final thumbnailBytes = isCurrentUser
        ? ref.watch(ownAvatarProvider).valueOrNull
        : ref
              .watch(
                memberAvatarThumbnailProvider(
                  MemberAvatarKey(mlsGroupId: groupId!, pubkeyHex: pubkey),
                ),
              )
              .valueOrNull;

    // On loading or error: show initials (no shimmer — bystander privacy).
    // On data: show HavenAvatar with image bytes when non-null.
    //
    // Wrap the whole initials-or-image decision in a single AnimatedSwitcher
    // so a nil→image transition crossfades rather than hard-popping.
    // The ValueKey differentiates the two widget types so Flutter knows to
    // animate the swap. No shimmer — bystander privacy.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: thumbnailBytes == null
          ? KeyedSubtree(key: const ValueKey('initials'), child: initialsAvatar)
          : HavenAvatar(
              key: const ValueKey('image'),
              imageBytes: thumbnailBytes,
              initials: initial,
              publicKey: pubkey,
              size: HavenAvatarSize.small,
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
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: onRetry,
            tooltip: 'Retry validation',
          ),
          if (onRemove != null) ...[
            const SizedBox(width: HavenSpacing.xs),
            IconButton(
              icon: const Icon(LucideIcons.x),
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
        icon: const Icon(LucideIcons.x),
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
        child: const Icon(
          LucideIcons.circleCheck,
          color: HavenSecurityColors.encrypted,
          semanticLabel: 'Valid',
        ),
      ),
      ValidationStatus.invalid => CircleAvatar(
        backgroundColor: HavenSecurityColors.warning.withValues(alpha: 0.1),
        child: const Icon(
          LucideIcons.triangleAlert,
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
