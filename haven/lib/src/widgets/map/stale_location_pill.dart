/// Offline/stale location indicator pill.
///
/// Rendered above the map when any member location markers have been
/// hydrated from the persistent last-known-location cache without a
/// fresh relay confirmation this session. Communicates to the user
/// that the pins shown are historical rather than live.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A small pill-shaped banner indicating that at least one map marker
/// is showing a cached (stale) last-known location.
class StaleLocationPill extends StatelessWidget {
  /// Creates a stale location pill.
  const StaleLocationPill({required this.staleCount, super.key});

  /// Number of stale markers currently shown on the map.
  final int staleCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final label = staleCount == 1
        ? 'Showing 1 cached location'
        : 'Showing $staleCount cached locations';

    return Semantics(
      label: '$label. Not live — last seen from persistent cache.',
      child: Material(
        color: colorScheme.surfaceContainerHigh,
        elevation: 3,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.base,
            vertical: HavenSpacing.sm,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: HavenSpacing.sm),
              Text(
                label,
                style: textTheme.labelMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
