/// Badge displaying invitation status for circle members.
///
/// Uses icon + text + color for accessibility compliance.
library;

import 'package:flutter/material.dart';

import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';

/// Displays a member's invitation status as a badge.
///
/// Shows icon + text for accessibility (not color-only).
class InvitationStatusBadge extends StatelessWidget {
  /// Creates an [InvitationStatusBadge].
  const InvitationStatusBadge({
    required this.status,
    this.compact = false,
    super.key,
  });

  /// The membership status to display.
  final MembershipStatus status;

  /// Whether to show a compact version (icon only).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = _getStatusDisplay();

    if (status == MembershipStatus.accepted) {
      // Don't show badge for accepted members
      return const SizedBox.shrink();
    }

    return Semantics(
      label: 'Invitation status: $label',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? HavenSpacing.xs : HavenSpacing.sm,
          vertical: HavenSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(HavenSpacing.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            if (!compact) ...[
              const SizedBox(width: HavenSpacing.xs),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  (IconData, String, Color) _getStatusDisplay() {
    return switch (status) {
      MembershipStatus.pending => (
        Icons.schedule,
        'Invitation Pending',
        HavenSecurityColors.warning,
      ),
      MembershipStatus.accepted => (
        Icons.check_circle,
        'Active',
        HavenSecurityColors.encrypted,
      ),
      MembershipStatus.declined => (
        Icons.cancel,
        'Declined',
        HavenSecurityColors.danger,
      ),
    };
  }
}
