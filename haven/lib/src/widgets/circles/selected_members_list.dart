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
    this.names = const {},
    this.maxVisible = 3,
    super.key,
  });

  /// Identifiers of the staged members, each shortened by
  /// [NpubValidator.shortenForDisplay].
  ///
  /// The only caller (`name_circle_page.dart`) passes each KeyPackage's
  /// verified author as an npub, so what a user reads here can be
  /// cross-checked against the npub they were handed
  /// (docs/MEMBER_PICKER_PLAN.md §7.1).
  final List<String> members;

  /// Resolved names, keyed by the identifier in [members]. A member with no
  /// entry is shown by the key alone; one with an entry by the name with the
  /// key beneath it, because a name is chosen by whoever published it.
  final Map<String, String> names;

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
          (member) =>
              _CompactMemberChip(identifier: member, name: names[member]),
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
  const _CompactMemberChip({required this.identifier, this.name});

  final String identifier;

  final String? name;

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
      // No `maxLines`/`overflow` on the identifier: it wraps rather than
      // clipping, because the trailing characters are what distinguish two
      // staged members from one another. Forced LTR: a bech32 key laid out
      // right-to-left is a different string to the eye.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (name case final name?)
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Text(
            NpubValidator.shortenForDisplay(identifier),
            textDirection: TextDirection.ltr,
            style: HavenTypography.monoSmall,
          ),
        ],
      ),
    );
  }
}
