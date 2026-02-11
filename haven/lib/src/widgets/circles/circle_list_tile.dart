/// Circle list item widget for displaying circles in a list.
///
/// Displays a circle with its name, member count, and encryption status.
/// Tapping the tile selects the circle for viewing details.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/theme/theme.dart';

/// A list tile displaying a circle.
///
/// Shows the circle name, member count, and indicates E2E encryption.
/// Selecting this tile updates [selectedCircleProvider] to show the
/// circle's members in the bottom sheet.
class CircleListTile extends ConsumerWidget {
  /// Creates a [CircleListTile] for the given circle.
  const CircleListTile({required this.circle, super.key});

  /// The circle to display.
  final Circle circle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Get first letter of circle name for avatar
    final initial = circle.displayName.isNotEmpty
        ? circle.displayName[0].toUpperCase()
        : '?';

    // Count members (total count, not just accepted)
    final memberCount = circle.members.length;
    final memberText = memberCount == 1 ? '1 member' : '$memberCount members';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: colorScheme.primaryContainer,
        foregroundColor: colorScheme.onPrimaryContainer,
        child: Text(initial),
      ),
      title: Text(circle.displayName),
      subtitle: Text(memberText),
      trailing: const Icon(
        Icons.lock,
        color: HavenSecurityColors.encrypted,
        size: 20,
        semanticLabel: 'End-to-end encrypted',
      ),
      onTap: () {
        // Set the selected circle in the provider
        ref.read(selectedCircleProvider.notifier).state = circle;
      },
    );
  }
}
