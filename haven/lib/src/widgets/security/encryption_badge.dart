/// Encryption badge widget for Haven.
///
/// Displays end-to-end encryption status indicators.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A badge indicating end-to-end encryption status.
///
/// Displays a shield icon with optional label to indicate that
/// content is encrypted using the Marmot Protocol (MLS + Nostr).
class EncryptionBadge extends StatelessWidget {
  /// Creates an encryption badge.
  ///
  /// Set [showLabel] to true to display "E2E Encrypted" text.
  const EncryptionBadge({
    super.key,
    this.showLabel = false,
    this.size = EncryptionBadgeSize.medium,
  });

  /// Whether to show the "E2E Encrypted" label.
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
        message: 'End-to-end encrypted',
        child: Icon(
          Icons.lock,
          size: iconSize,
          color: HavenSecurityColors.encrypted,
          semanticLabel: 'End-to-end encrypted',
        ),
      );
    }

    return Semantics(
      label: 'End-to-end encrypted',
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
            Text('E2E Encrypted', style: textStyle),
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
