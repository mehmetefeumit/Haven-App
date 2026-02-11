/// List of selected members shown as removable chips.
library;

import 'package:flutter/material.dart';

import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';

/// Displays selected members as removable chips.
class SelectedMembersList extends StatelessWidget {
  /// Creates a [SelectedMembersList].
  const SelectedMembersList({
    required this.members,
    required this.onRemove,
    super.key,
  });

  /// List of selected member npubs.
  final List<String> members;

  /// Callback when a member is removed.
  final void Function(String npub) onRemove;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: HavenSpacing.sm,
      runSpacing: HavenSpacing.sm,
      children: members.map((npub) {
        return _MemberChip(npub: npub, onDelete: () => onRemove(npub));
      }).toList(),
    );
  }
}

class _MemberChip extends StatelessWidget {
  const _MemberChip({required this.npub, required this.onDelete});

  final String npub;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    // Generate a color from the pubkey for visual distinction
    final colorIndex = npub.hashCode.abs() % Colors.primaries.length;
    final avatarColor = Colors.primaries[colorIndex];

    return InputChip(
      avatar: CircleAvatar(
        backgroundColor: avatarColor.withValues(alpha: 0.2),
        child: Text(
          npub[5].toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: avatarColor.shade700,
          ),
        ),
      ),
      label: Text(
        NpubValidator.truncate(npub, prefixLength: 8, suffixLength: 4),
        style: HavenTypography.mono.copyWith(fontSize: 12),
      ),
      onDeleted: onDelete,
      deleteIcon: const Icon(Icons.close, size: 18),
    );
  }
}

/// Displays a compact summary of selected members.
///
/// Shows first few members as chips with a "+N more" indicator.
class SelectedMembersSummary extends StatelessWidget {
  /// Creates a [SelectedMembersSummary].
  const SelectedMembersSummary({
    required this.members,
    this.maxVisible = 3,
    super.key,
  });

  /// List of member npubs.
  final List<String> members;

  /// Maximum number of chips to show before "+N more".
  final int maxVisible;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return const SizedBox.shrink();
    }

    final visibleMembers = members.take(maxVisible).toList();
    final remainingCount = members.length - visibleMembers.length;

    return Wrap(
      spacing: HavenSpacing.xs,
      runSpacing: HavenSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...visibleMembers.map((npub) => _CompactMemberChip(npub: npub)),
        if (remainingCount > 0)
          Text(
            '+$remainingCount more',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _CompactMemberChip extends StatelessWidget {
  const _CompactMemberChip({required this.npub});

  final String npub;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(HavenSpacing.xs),
      ),
      child: Text(
        NpubValidator.truncate(npub, prefixLength: 6, suffixLength: 3),
        style: HavenTypography.monoSmall,
      ),
    );
  }
}
