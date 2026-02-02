/// Spacing constants following an 8pt grid system.
///
/// These values ensure consistent spacing throughout the Haven app,
/// aligned with Material Design guidelines.
library;

/// Spacing tokens for consistent layout throughout the app.
///
/// Uses an 8pt grid system where most values are multiples of 8.
/// The [md] value (12) provides a middle ground between [sm] and [base].
abstract final class HavenSpacing {
  /// Extra small spacing: 4dp.
  ///
  /// Use for tight spacing within components, such as icon padding.
  static const double xs = 4;

  /// Small spacing: 8dp.
  ///
  /// Use for spacing between related elements within a component.
  static const double sm = 8;

  /// Medium spacing: 12dp.
  ///
  /// Use for moderate spacing, between [sm] and [base].
  static const double md = 12;

  /// Base spacing: 16dp.
  ///
  /// The standard spacing unit for most layout needs.
  static const double base = 16;

  /// Large spacing: 24dp.
  ///
  /// Use for spacing between distinct sections or groups.
  static const double lg = 24;

  /// Extra large spacing: 32dp.
  ///
  /// Use for major section breaks or page margins.
  static const double xl = 32;

  /// Double extra large spacing: 48dp.
  ///
  /// Use for significant visual separation, such as between page sections.
  static const double xxl = 48;
}
