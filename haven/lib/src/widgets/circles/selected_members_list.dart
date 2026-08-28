/// Compact summary of the members staged for a new circle.
library;

import 'package:flutter/material.dart';

import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/utils/npub_validator.dart';

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

  /// Identifiers of the staged members, each shortened by
  /// [NpubValidator.shortenForDisplay].
  ///
  /// The only caller (`name_circle_page.dart`) passes KeyPackage **hex**
  /// pubkeys rather than npubs, so what a user reads here is a hex fragment:
  /// enough to tell two staged members apart, but not something they can
  /// cross-check against the npub they were handed
  /// (docs/MEMBER_PICKER_PLAN.md §7.1).
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
        ...visibleMembers.map(
          (member) => _CompactMemberChip(identifier: member),
        ),
        if (remainingCount > 0)
          Text(
            AppLocalizations.of(context).selectedMembersMore(remainingCount),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

class _CompactMemberChip extends StatelessWidget {
  const _CompactMemberChip({required this.identifier});

  final String identifier;

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
      // No `maxLines`/`overflow`: the identifier wraps rather than clipping,
      // because the trailing characters are what distinguish two staged
      // members from one another.
      child: Text(
        NpubValidator.shortenForDisplay(identifier),
        style: HavenTypography.monoSmall,
      ),
    );
  }
}
