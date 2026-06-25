/// Haven app theme configuration.
///
/// Achromatic monochrome surfaces with semantic-only color, tightened
/// geometry, and hairline borders in place of M3 surface tinting. The
/// `ColorScheme` literals below are explicit (not `fromSeed`) so no hue
/// derivatives leak into containers, FABs, or scrolled-under app bars.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/colors.dart';
import 'package:haven/src/theme/spacing.dart';
import 'package:haven/src/theme/typography.dart';

const double _radiusButton = 4;
const double _radiusCard = 8;
const double _radiusDialog = 12;

const ColorScheme _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFF0A0A0A),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFF2F2F2),
  onPrimaryContainer: Color(0xFF0A0A0A),
  secondary: Color(0xFF525252),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFFAFAFA),
  onSecondaryContainer: Color(0xFF0A0A0A),
  tertiary: Color(0xFF525252),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFF2F2F2),
  onTertiaryContainer: Color(0xFF0A0A0A),
  error: Color(0xFFDC2626),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFEE2E2),
  onErrorContainer: Color(0xFF7F1D1D),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF0A0A0A),
  onSurfaceVariant: Color(0xFF525252),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFFAFAFA),
  surfaceContainer: Color(0xFFF5F5F5),
  surfaceContainerHigh: Color(0xFFF2F2F2),
  surfaceContainerHighest: Color(0xFFE5E5E5),
  outline: Color(0xFFE0E0E0),
  outlineVariant: Color(0xFFEBEBEB),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF0A0A0A),
  onInverseSurface: Color(0xFFFFFFFF),
  inversePrimary: Color(0xFFFAFAFA),
  surfaceTint: Colors.transparent,
);

const ColorScheme _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFFAFAFA),
  onPrimary: Color(0xFF0A0A0A),
  primaryContainer: Color(0xFF1F1F1F),
  onPrimaryContainer: Color(0xFFFAFAFA),
  secondary: Color(0xFFA3A3A3),
  onSecondary: Color(0xFF0A0A0A),
  secondaryContainer: Color(0xFF1F1F1F),
  onSecondaryContainer: Color(0xFFFAFAFA),
  tertiary: Color(0xFFA3A3A3),
  onTertiary: Color(0xFF0A0A0A),
  tertiaryContainer: Color(0xFF1F1F1F),
  onTertiaryContainer: Color(0xFFFAFAFA),
  error: Color(0xFFFCA5A5),
  onError: Color(0xFF0A0A0A),
  errorContainer: Color(0xFF7F1D1D),
  onErrorContainer: Color(0xFFFCA5A5),
  surface: Color(0xFF0A0A0A),
  onSurface: Color(0xFFFAFAFA),
  onSurfaceVariant: Color(0xFFA3A3A3),
  surfaceContainerLowest: Color(0xFF000000),
  surfaceContainerLow: Color(0xFF141414),
  surfaceContainer: Color(0xFF1A1A1A),
  surfaceContainerHigh: Color(0xFF1F1F1F),
  surfaceContainerHighest: Color(0xFF2A2A2A),
  outline: Color(0xFF2A2A2A),
  outlineVariant: Color(0xFF1A1A1A),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFFAFAFA),
  onInverseSurface: Color(0xFF0A0A0A),
  inversePrimary: Color(0xFF0A0A0A),
  surfaceTint: Colors.transparent,
);

/// Theme factory for Haven app themes.
abstract final class HavenTheme {
  /// Creates the light theme.
  static ThemeData light() => _build(_lightScheme, isLight: true);

  /// Creates the dark theme.
  static ThemeData dark() => _build(_darkScheme, isLight: false);

  static ThemeData _build(ColorScheme scheme, {required bool isLight}) {
    final cardSurface = isLight
        ? HavenLightSurface.cardBackground
        : HavenDarkSurface.cardBackground;
    final inputSurface = isLight
        ? HavenLightSurface.inputBackground
        : HavenDarkSurface.inputBackground;
    final dividerColor = isLight
        ? HavenLightSurface.divider
        : HavenDarkSurface.divider;

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radiusButton),
    );
    final inputShape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(_radiusButton),
      borderSide: BorderSide.none,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: HavenTypography.buildTextTheme(scheme.brightness),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        // The leading back button is centred in a fixed 56px slot, so its
        // glyph sits 4px further from the edge than a flush-right action
        // icon does. That asymmetry reads as an off-centre app bar. Add 4px
        // of trailing padding so trailing action icons match the back
        // button's inset on both edges. Directional so it mirrors in RTL.
        actionsPadding: const EdgeInsetsDirectional.only(end: 4),
      ),
      cardTheme: CardThemeData(
        color: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: isLight ? 0 : 0.5,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusCard),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.lg,
            vertical: HavenSpacing.base,
          ),
          shape: buttonShape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.lg,
            vertical: HavenSpacing.base,
          ),
          side: BorderSide(color: scheme.outline),
          shape: buttonShape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.base,
            vertical: HavenSpacing.sm,
          ),
          shape: buttonShape,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputSurface,
        border: inputShape,
        enabledBorder: inputShape,
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radiusButton),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.base,
          vertical: HavenSpacing.md,
        ),
      ),
      dividerTheme: DividerThemeData(color: dividerColor, thickness: 1),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusButton),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardSurface,
        surfaceTintColor: Colors.transparent,
        elevation: isLight ? 0 : 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusDialog),
          side: BorderSide(color: scheme.outlineVariant, width: 1),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: scheme.surface,
        modalBarrierColor: Colors.black.withValues(alpha: 0.4),
        elevation: isLight ? 0 : 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.lg,
            vertical: HavenSpacing.base,
          ),
          minimumSize: const Size(48, 48),
          shape: buttonShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusButton),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        type: BottomNavigationBarType.fixed,
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.surfaceContainerHigh,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: isLight ? 0 : 1,
        focusElevation: isLight ? 0 : 1,
        hoverElevation: isLight ? 1 : 2,
        highlightElevation: isLight ? 1 : 2,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radiusButton),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
      ),
    );
  }
}
