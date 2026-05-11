/// Privacy chip widget for Haven.
///
/// Displays location privacy/precision levels with visual indicators.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

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
                Icon(LucideIcons.chevronDown, size: 18, color: level.color),
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

  /// Neighborhood-level precision (~11m).
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
  ///
  /// Distances match the Rust `LocationPrecision` decimal-place radii:
  /// Enhanced = 5 dp (~1.1 m), Standard = 4 dp (~11 m), Private = 2 dp (~1.1 km).
  String get description => switch (this) {
    PrivacyLevel.exact => 'Share precise location (~1m accuracy)',
    PrivacyLevel.neighborhood => 'Share approximate area (~11m)',
    PrivacyLevel.city => 'Share approximate area (~1km)',
    PrivacyLevel.hidden => "Don't share location at all",
  };

  /// Icon representing this privacy level.
  IconData get icon => switch (this) {
    PrivacyLevel.exact => LucideIcons.locateFixed,
    PrivacyLevel.neighborhood => LucideIcons.mapPin,
    PrivacyLevel.city => LucideIcons.building2,
    PrivacyLevel.hidden => LucideIcons.mapPinOff,
  };
}

/// FFI mapping from [PrivacyLevel] to the Rust `LocationPrecision` label
/// string accepted by [`LocationPrecision::from_label`].
///
/// Returns `null` for [PrivacyLevel.hidden] — callers must suppress
/// publishing entirely when the user has chosen to hide their location.
extension PrivacyLevelFfi on PrivacyLevel {
  /// The Rust-side `LocationPrecision` label, or `null` for stealth mode.
  String? get ffiLabel => switch (this) {
    PrivacyLevel.exact => 'Enhanced',
    PrivacyLevel.neighborhood => 'Standard',
    PrivacyLevel.city => 'Private',
    PrivacyLevel.hidden => null,
  };
}
