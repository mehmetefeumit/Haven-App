/// Circle list item widget for displaying circles in a list.
///
/// Displays a circle with its name, member count, and encryption status.
/// Tapping the tile selects the circle for viewing details.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/utils/profile_refresh_trigger.dart';

/// A list tile displaying a circle.
///
/// Shows the circle name, member count, and indicates encryption status.
/// Selecting this tile updates [selectedCircleIdProvider] to show the
/// circle's members in the bottom sheet.
class CircleListTile extends ConsumerWidget {
  /// Creates a [CircleListTile] for the given circle.
  const CircleListTile({required this.circle, super.key});

  /// The circle to display.
  final Circle circle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Get first grapheme cluster of circle name for avatar.
    final initial = circle.displayName.isNotEmpty
        ? circle.displayName.characters.first.toUpperCase()
        : '?';

    // Count members (total count, not just accepted)
    final memberText = l10n.commonMemberCount(circle.members.length);

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        child: Text(initial),
      ),
      title: Text(circle.displayName),
      subtitle: Text(memberText),
      onTap: () {
        // Set the selected circle in the provider
        ref.read(selectedCircleIdProvider.notifier).state = circle.mlsGroupId;
        // §6.2: refresh member/own public profiles on circle-select.
        triggerProfileRefresh(
          ref,
          ref.read(circlesProvider).valueOrNull ?? const [],
        );
      },
    );
  }
}
