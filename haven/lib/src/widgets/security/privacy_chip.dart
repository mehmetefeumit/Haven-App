/// Privacy chip widget for Haven.
///
/// Displays location privacy/precision levels with visual indicators.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A chip displaying the current location privacy level.
///
/// Shows both an icon and label indicating how precisely location
/// is being shared.
class PrivacyChip extends StatelessWidget {
  /// Creates a privacy chip.
  const PrivacyChip({required this.level, super.key, this.onTap});

  /// The privacy level to display.
  final PrivacyLevel level;

  /// Callback when the chip is tapped (for changing privacy level).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tapHint = onTap != null ? '. Tap to change' : '';

    return Semantics(
      label: 'Privacy level: ${level.label}$tapHint',
      button: onTap != null,
      enabled: onTap != null,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.md,
            vertical: HavenSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: level.color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(HavenSpacing.base),
            border: Border.all(color: level.color.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(level.icon, size: 16, color: level.color),
              const SizedBox(width: HavenSpacing.sm),
              Text(
                level.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: level.color,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: HavenSpacing.xs),
                Icon(Icons.arrow_drop_down, size: 18, color: level.color),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Location privacy/precision levels.
///
/// These correspond to how precisely location is shared with circle members.
enum PrivacyLevel {
  /// Exact location (~1-10m precision).
  exact,

  /// Neighborhood-level precision (~100m).
  neighborhood,

  /// City-level precision (~1km).
  city,

  /// Location not shared.
  hidden,
}

/// UI extension for [PrivacyLevel] providing consistent visual properties.
extension PrivacyLevelUI on PrivacyLevel {
  /// The semantic color for this privacy level.
  Color get color => switch (this) {
    PrivacyLevel.exact => HavenPrivacyColors.exact,
    PrivacyLevel.neighborhood => HavenPrivacyColors.neighborhood,
    PrivacyLevel.city => HavenPrivacyColors.city,
    PrivacyLevel.hidden => HavenPrivacyColors.hidden,
  };

  /// Short label for this privacy level.
  String get label => switch (this) {
    PrivacyLevel.exact => 'Exact',
    PrivacyLevel.neighborhood => 'Neighborhood',
    PrivacyLevel.city => 'City',
    PrivacyLevel.hidden => 'Hidden',
  };

  /// Full label with "Location" suffix.
  String get fullLabel => switch (this) {
    PrivacyLevel.exact => 'Exact Location',
    PrivacyLevel.neighborhood => 'Neighborhood',
    PrivacyLevel.city => 'City',
    PrivacyLevel.hidden => 'Hidden',
  };

  /// Description of precision for this level.
  String get description => switch (this) {
    PrivacyLevel.exact => 'Share precise location (~1m accuracy)',
    PrivacyLevel.neighborhood => 'Share approximate area (~100m)',
    PrivacyLevel.city => 'Share city-level only (~1km)',
    PrivacyLevel.hidden => "Don't share location at all",
  };

  /// Icon representing this privacy level.
  IconData get icon => switch (this) {
    PrivacyLevel.exact => Icons.my_location,
    PrivacyLevel.neighborhood => Icons.location_on,
    PrivacyLevel.city => Icons.location_city,
    PrivacyLevel.hidden => Icons.location_off,
  };
}
