/// Typography styles for the Haven design system.
///
/// Body text uses Inter (variable, bundled). Monospace styles use
/// JetBrains Mono and are reserved for *verifiable* data — pubkey hex,
/// relay URLs, coordinates, event IDs, build hashes — never for
/// glanceable HUD chrome like age pills or button labels. The mono
/// signal stays meaningful when used sparingly.
library;

import 'package:flutter/material.dart';

const String _sansFamily = 'Inter';
const String _monoFamily = 'JetBrainsMono';

const List<String> _sansFallback = [
  'Roboto',
  'SF Pro Text',
  'Helvetica Neue',
  'Arial',
];
const List<String> _monoFallback = [
  'Roboto Mono',
  'Menlo',
  'Consolas',
  'monospace',
];

/// Typography configuration for Haven.
abstract final class HavenTypography {
  /// Monospace text style for cryptographic keys and coordinates.
  static const TextStyle mono = TextStyle(
    fontFamily: _monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: 12,
    letterSpacing: 0.5,
  );

  /// Large monospace text style for prominent key display.
  static const TextStyle monoLarge = TextStyle(
    fontFamily: _monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: 14,
    letterSpacing: 0.5,
  );

  /// Small monospace text style for compact key display.
  static const TextStyle monoSmall = TextStyle(
    fontFamily: _monoFamily,
    fontFamilyFallback: _monoFallback,
    fontSize: 10,
    letterSpacing: 0.3,
  );

  /// Returns a context-aware monospace text style.
  static TextStyle monoStyle(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextStyle(
      fontFamily: _monoFamily,
      fontFamilyFallback: _monoFallback,
      fontSize: 12,
      letterSpacing: 0.5,
      color: colorScheme.onSurface,
    );
  }

  /// Builds a custom TextTheme based on the given brightness.
  static TextTheme buildTextTheme(Brightness brightness) {
    final baseColor = brightness == Brightness.light
        ? const Color(0xFF0A0A0A)
        : const Color(0xFFFAFAFA);
    final mutedColor = brightness == Brightness.light
        ? const Color(0xFF525252)
        : const Color(0xFFA3A3A3);

    TextStyle style({
      required double fontSize,
      FontWeight fontWeight = FontWeight.w400,
      double? letterSpacing,
      Color? color,
    }) => TextStyle(
      fontFamily: _sansFamily,
      fontFamilyFallback: _sansFallback,
      fontSize: fontSize,
      fontWeight: fontWeight,
      letterSpacing: letterSpacing,
      color: color ?? baseColor,
    );

    return TextTheme(
      displayLarge: style(fontSize: 57, letterSpacing: -0.25),
      displayMedium: style(fontSize: 45),
      displaySmall: style(fontSize: 36),
      headlineLarge: style(fontSize: 32, fontWeight: FontWeight.w600),
      headlineMedium: style(fontSize: 28, fontWeight: FontWeight.w600),
      headlineSmall: style(fontSize: 24, fontWeight: FontWeight.w600),
      titleLarge: style(fontSize: 22, fontWeight: FontWeight.w500),
      titleMedium: style(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.15,
      ),
      titleSmall: style(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
      ),
      bodyLarge: style(fontSize: 16, letterSpacing: 0.5),
      bodyMedium: style(fontSize: 14, letterSpacing: 0.25),
      bodySmall: style(fontSize: 12, letterSpacing: 0.4, color: mutedColor),
      labelLarge: style(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.1,
      ),
      labelMedium: style(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
      ),
      labelSmall: style(
        fontSize: 11,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: mutedColor,
      ),
    );
  }
}
