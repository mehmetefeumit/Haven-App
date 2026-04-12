/// Encryption badge widget for Haven.
///
/// Displays encryption status indicators.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A badge indicating encryption status.
///
/// Displays a lock icon with optional label to indicate that
/// content is encrypted.
class EncryptionBadge extends StatelessWidget {
  /// Creates an encryption badge.
  ///
  /// Set [showLabel] to true to display "Encrypted" text.
  const EncryptionBadge({
    super.key,
    this.showLabel = false,
    this.size = EncryptionBadgeSize.medium,
  });

  /// Whether to show the "Encrypted" label.
  final bool showLabel;

  /// The size of the badge.
  final EncryptionBadgeSize size;

  @override
  Widget build(BuildContext context) {
    final iconSize = switch (size) {
      EncryptionBadgeSize.small => 16.0,
      EncryptionBadgeSize.medium => 20.0,
      EncryptionBadgeSize.large => 24.0,
    };

    final textStyle = switch (size) {
      EncryptionBadgeSize.small => Theme.of(
        context,
      ).textTheme.labelSmall?.copyWith(color: HavenSecurityColors.encrypted),
      EncryptionBadgeSize.medium => Theme.of(
        context,
      ).textTheme.labelMedium?.copyWith(color: HavenSecurityColors.encrypted),
      EncryptionBadgeSize.large => Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(color: HavenSecurityColors.encrypted),
    };

    if (!showLabel) {
      return Tooltip(
        message: 'Encrypted',
        child: Icon(
          Icons.lock,
          size: iconSize,
          color: HavenSecurityColors.encrypted,
          semanticLabel: 'Encrypted',
        ),
      );
    }

    return Semantics(
      label: 'Encrypted',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.sm,
          vertical: HavenSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: HavenSecurityColors.encrypted.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(HavenSpacing.xs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock,
              size: iconSize,
              color: HavenSecurityColors.encrypted,
            ),
            const SizedBox(width: HavenSpacing.xs),
            Text('Encrypted', style: textStyle),
          ],
        ),
      ),
    );
  }
}

/// Size variants for the encryption badge.
enum EncryptionBadgeSize {
  /// Small badge for compact UI elements.
  small,

  /// Medium badge for standard use.
  medium,

  /// Large badge for prominent display.
  large,
}
