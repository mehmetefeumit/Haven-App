/// Typography styles for the Haven design system.
///
/// Follows Material 3 type scale with semantic naming for
/// consistent text styling throughout the app.
library;

import 'package:flutter/material.dart';

/// Typography configuration for Haven.
///
/// Provides text styles that complement Material 3's type system
/// with Haven-specific customizations for readability.
abstract final class HavenTypography {
  /// Monospace text style for cryptographic keys and coordinates.
  ///
  /// Uses a consistent monospace font for technical data display,
  /// ensuring characters are distinguishable (e.g., 0 vs O, l vs 1).
  static const TextStyle mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    letterSpacing: 0.5,
  );

  /// Large monospace text style for prominent key display.
  static const TextStyle monoLarge = TextStyle(
    fontFamily: 'monospace',
    fontSize: 14,
    letterSpacing: 0.5,
  );

  /// Small monospace text style for compact key display.
  static const TextStyle monoSmall = TextStyle(
    fontFamily: 'monospace',
    fontSize: 10,
    letterSpacing: 0.3,
  );

  /// Returns a context-aware monospace text style.
  ///
  /// Uses the current theme's color scheme for proper contrast.
  static TextStyle monoStyle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      letterSpacing: 0.5,
      color: colorScheme.onSurface,
    );
  }

  /// Builds a custom TextTheme based on the given brightness.
  ///
  /// This extends the default Material 3 text theme with Haven-specific
  /// modifications while maintaining accessibility standards.
  static TextTheme buildTextTheme(Brightness brightness) {
    final baseColor = brightness == Brightness.light
        ? Colors.black
        : Colors.white;

    return TextTheme(
      // Display styles - for hero numbers and large text
      displayLarge: TextStyle(
        fontSize: 57,
        fontWeight: FontWeight.w400,
        letterSpacing: -0.25,
        color: baseColor,
      ),
      displayMedium: TextStyle(
        fontSize: 45,
        fontWeight: FontWeight.w400,
        color: baseColor,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        fontWeight: FontWeight.w400,
        color: baseColor,
      ),

      // Headline styles - for page titles and section headers
      headlineLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        color: baseColor,
      ),
      headlineMedium: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: baseColor,
      ),
      headlineSmall: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: baseColor,
      ),

      // Title styles - for card titles and list items
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w500,
        color: baseColor,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.15,
        color: baseColor,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: baseColor,
      ),

      // Body styles - for content and descriptions
      bodyLarge: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        color: baseColor,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        color: baseColor,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        color: baseColor.withValues(alpha: 0.7),
      ),

      // Label styles - for buttons and small UI elements
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
        color: baseColor,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: baseColor,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: baseColor.withValues(alpha: 0.7),
      ),
    );
  }
}
