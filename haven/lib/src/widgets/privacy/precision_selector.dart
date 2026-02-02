/// Precision selector widget for Haven.
///
/// Visual picker for location privacy/precision levels.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/security/privacy_chip.dart';

/// A visual selector for location precision levels.
///
/// Displays all precision options with icons, labels, and descriptions.
class PrecisionSelector extends StatelessWidget {
  /// Creates a precision selector.
  const PrecisionSelector({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Currently selected precision level.
  final PrivacyLevel selected;

  /// Callback when selection changes.
  final ValueChanged<PrivacyLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final level in PrivacyLevel.values)
          Padding(
            padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
            child: _PrecisionOption(
              level: level,
              isSelected: level == selected,
              onTap: () => onChanged(level),
            ),
          ),
      ],
    );
  }
}

class _PrecisionOption extends StatelessWidget {
  const _PrecisionOption({
    required this.level,
    required this.isSelected,
    required this.onTap,
  });

  final PrivacyLevel level;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: isSelected
          ? level.color.withValues(alpha: 0.1)
          : colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(HavenSpacing.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(HavenSpacing.md),
        child: Container(
          padding: const EdgeInsets.all(HavenSpacing.base),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(HavenSpacing.md),
            border: Border.all(
              color: isSelected ? level.color : Colors.transparent,
              width: isSelected ? 3 : 1, // Increased for better visibility
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(HavenSpacing.sm),
                decoration: BoxDecoration(
                  color: level.color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(HavenSpacing.sm),
                ),
                child: Icon(level.icon, color: level.color, size: 24),
              ),
              const SizedBox(width: HavenSpacing.base),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      level.fullLabel,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: isSelected ? level.color : null,
                        fontWeight: isSelected ? FontWeight.w600 : null,
                      ),
                    ),
                    const SizedBox(height: HavenSpacing.xs),
                    Text(
                      level.description,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: level.color)
              else
                Icon(Icons.circle_outlined, color: colorScheme.outlineVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact horizontal precision selector for inline use.
class CompactPrecisionSelector extends StatelessWidget {
  /// Creates a compact precision selector.
  const CompactPrecisionSelector({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// Currently selected precision level.
  final PrivacyLevel selected;

  /// Callback when selection changes.
  final ValueChanged<PrivacyLevel> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<PrivacyLevel>(
      segments: [
        for (final level in PrivacyLevel.values)
          ButtonSegment(
            value: level,
            icon: Icon(level.icon),
            tooltip: level.label,
          ),
      ],
      selected: {selected},
      onSelectionChanged: (set) {
        if (set.isNotEmpty) {
          onChanged(set.first);
        }
      },
      showSelectedIcon: false,
    );
  }
}
