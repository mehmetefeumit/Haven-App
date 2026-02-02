/// Semantic color tokens for the Haven design system.
///
/// Colors are organized by purpose rather than visual appearance,
/// making the design system more maintainable and accessible.
library;

import 'package:flutter/material.dart';

/// Privacy-related colors indicating location precision levels.
///
/// These colors help users understand how precisely their location
/// is being shared with circle members.
abstract final class HavenPrivacyColors {
  /// Exact location precision (~1m accuracy).
  ///
  /// Green indicates full precision sharing.
  static const Color exact = Color(0xFF4CAF50);

  /// Neighborhood precision (~100m accuracy).
  ///
  /// Blue indicates approximate area sharing.
  static const Color neighborhood = Color(0xFF2196F3);

  /// City-level precision (~1km accuracy).
  ///
  /// Orange indicates broad area sharing.
  static const Color city = Color(0xFFFFA726);

  /// Location hidden (not sharing).
  ///
  /// Gray indicates location is not being shared.
  static const Color hidden = Color(0xFF9E9E9E);
}

/// Security indicator colors for encryption and trust status.
///
/// These colors provide visual feedback about the security state
/// of communications and identity verification.
abstract final class HavenSecurityColors {
  /// Encrypted and secure state.
  ///
  /// Green indicates end-to-end encryption is active.
  static const Color encrypted = Color(0xFF4CAF50);

  /// Warning state requiring attention.
  ///
  /// Orange indicates a potential security concern.
  static const Color warning = Color(0xFFFF9800);

  /// Danger state indicating a security risk.
  ///
  /// Red indicates an active security threat or error.
  static const Color danger = Color(0xFFE53935);
}

/// Location freshness colors indicating when a location was last updated.
///
/// These colors help users understand how recent a member's location is,
/// which is important for real-time location sharing.
abstract final class HavenFreshnessColors {
  /// Live location (updated within the last minute).
  ///
  /// Green indicates the location is current.
  static const Color live = Color(0xFF4CAF50);

  /// Recent location (updated within the last 5 minutes).
  ///
  /// Blue indicates the location is fairly recent.
  static const Color recent = Color(0xFF2196F3);

  /// Stale location (updated within the last 15 minutes).
  ///
  /// Orange indicates the location may be outdated.
  static const Color stale = Color(0xFFFFA726);

  /// Old location (updated more than 15 minutes ago).
  ///
  /// Gray indicates the location is likely outdated.
  static const Color old = Color(0xFF9E9E9E);
}

/// Status colors for member online/offline state.
///
/// These colors indicate whether a circle member is currently active
/// in the app and sharing their location.
abstract final class HavenStatusColors {
  /// Member is online and actively sharing.
  static const Color online = Color(0xFF4CAF50);

  /// Member is offline or not sharing.
  static const Color offline = Color(0xFF9E9E9E);

  /// Member is away (app backgrounded but still sharing).
  static const Color away = Color(0xFFFFA726);
}

/// Primary brand color used as the seed for Material color schemes.
///
/// This blue is the foundation of Haven's visual identity.
const Color havenPrimaryColor = Color(0xFF1976D2);

/// Light theme surface colors with appropriate contrast.
abstract final class HavenLightSurface {
  /// Background color for cards on primary surface.
  static const Color cardBackground = Color(0xFFFAFAFA);

  /// Subtle background for input fields and containers.
  static const Color inputBackground = Color(0xFFF5F5F5);

  /// Divider color for separating content.
  static const Color divider = Color(0xFFE0E0E0);
}

/// Dark theme surface colors with appropriate contrast.
abstract final class HavenDarkSurface {
  /// Background color for cards on primary surface.
  static const Color cardBackground = Color(0xFF2C2C2C);

  /// Subtle background for input fields and containers.
  static const Color inputBackground = Color(0xFF3C3C3C);

  /// Divider color for separating content.
  static const Color divider = Color(0xFF424242);
}
