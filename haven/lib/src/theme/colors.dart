/// Semantic color tokens for the Haven design system.
///
/// Haven uses an achromatic monochrome base (near-white surfaces in light
/// theme, near-black in dark) so color appears in the UI only when it
/// carries meaning — encrypted state, online state, warning, danger.
/// This keeps the cypherpunk character honest: a green pixel always
/// communicates security, never decoration.
library;

import 'package:flutter/material.dart';

/// Security indicator colors for encryption and trust status.
///
/// These three colors are the only places hue should "speak" loudly
/// in the app: an active E2EE session, a state needing attention,
/// or an outright security risk.
abstract final class HavenSecurityColors {
  /// Encrypted and secure state — end-to-end encryption is active.
  static const Color encrypted = Color(0xFF16A34A);

  /// Warning state requiring user attention.
  static const Color warning = Color(0xFFD97706);

  /// Danger state indicating a security risk or destructive action.
  static const Color danger = Color(0xFFDC2626);
}

/// Status colors for member online/offline state.
///
/// Online intentionally shares the green with encrypted/exact —
/// "active, sharing, secure" is one semantic family.
abstract final class HavenStatusColors {
  /// Member is online and actively sharing.
  static const Color online = Color(0xFF16A34A);

  /// Member is offline or not sharing.
  static const Color offline = Color(0xFF737373);

  /// Member is away (app backgrounded but still sharing).
  static const Color away = Color(0xFFD97706);
}

/// Achromatic primary used as the backbone of the color scheme.
///
/// Near-black in light theme; the dark theme inverts to near-white via
/// the explicit ColorScheme literal in `app_theme.dart`. Color appears
/// elsewhere in the UI only via the semantic palettes above.
const Color havenPrimaryColor = Color(0xFF0A0A0A);

/// Light theme surface colors.
abstract final class HavenLightSurface {
  /// Primary card surface — true white.
  static const Color cardBackground = Color(0xFFFFFFFF);

  /// Subtle background for input fields and recessed containers.
  static const Color inputBackground = Color(0xFFFAFAFA);

  /// Hairline color for dividers and 1px borders that replace elevation.
  static const Color divider = Color(0xFFE0E0E0);
}

/// Dark theme surface colors.
abstract final class HavenDarkSurface {
  /// Primary card surface — slightly lifted from the near-black background.
  static const Color cardBackground = Color(0xFF141414);

  /// Subtle background for input fields and recessed containers.
  static const Color inputBackground = Color(0xFF1F1F1F);

  /// Hairline color for dividers and 1px borders.
  static const Color divider = Color(0xFF2A2A2A);
}
