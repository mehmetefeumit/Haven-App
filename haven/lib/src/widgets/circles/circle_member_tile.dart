/// Tile displaying a circle member with status.
library;

import 'package:flutter/material.dart';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';
import 'package:haven/src/widgets/circles/invitation_status_badge.dart';

/// Displays a circle member with their status and actions.
class CircleMemberTile extends StatelessWidget {
  /// Creates a [CircleMemberTile].
  const CircleMemberTile({
    required this.member,
    this.onTap,
    this.trailing,
    super.key,
  });

  /// The member to display.
  final CircleMember member;

  /// Callback when the tile is tapped.
  final VoidCallback? onTap;

  /// Optional trailing widget (e.g., remove button).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ListTile(
      leading: _MemberAvatar(
        pubkey: member.pubkey,
        displayName: member.displayName,
      ),
      title: Text(
        member.displayName ?? NpubValidator.truncate(member.pubkey),
        style: member.displayName == null
            ? HavenTypography.mono.copyWith(fontSize: 14)
            : null,
      ),
      subtitle: _buildSubtitle(context, colorScheme),
      trailing: trailing ?? _buildTrailing(),
      onTap: onTap,
    );
  }

  Widget? _buildSubtitle(BuildContext context, ColorScheme colorScheme) {
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

    if (member.displayName != null) {
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

  Widget? _buildTrailing() {
    if (member.isAdmin) {
      return Chip(
        label: const Text('Admin'),
        labelStyle: const TextStyle(fontSize: 11),
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
      );
    }
    return null;
  }
}

class _MemberAvatar extends StatelessWidget {
  const _MemberAvatar({required this.pubkey, this.displayName});

  final String pubkey;
  final String? displayName;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Generate a color from the pubkey for visual distinction
    final colorIndex = pubkey.hashCode.abs() % Colors.primaries.length;
    final avatarColor = Colors.primaries[colorIndex];

    final initial =
        (displayName?.isNotEmpty == true ? displayName![0] : pubkey[5])
            .toUpperCase();

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
