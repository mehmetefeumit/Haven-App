/// Dim overlay widget for Haven.
///
/// Displays a semi-transparent overlay that dims content behind it,
/// typically used when a bottom sheet is expanded.
library;

import 'package:flutter/material.dart';

/// An animated overlay that dims content behind it.
///
/// The [opacity] controls how dark the overlay appears, from 0.0 (invisible)
/// to 1.0 (maximum darkness at 50% black). Tapping the overlay triggers
/// [onTap] if provided, typically used to collapse an expanded sheet.
class DimOverlay extends StatelessWidget {
  /// Creates a dim overlay.
  const DimOverlay({required this.opacity, this.onTap, super.key});

  /// The opacity of the overlay, from 0.0 to 1.0.
  ///
  /// At 0.0, the overlay is invisible. At 1.0, the overlay is at
  /// maximum darkness (50% black).
  final double opacity;

  /// Called when the overlay is tapped.
  ///
  /// Typically used to collapse an expanded bottom sheet.
  final VoidCallback? onTap;

  /// Below this opacity the scrim is visually imperceptible (its black fill
  /// is `opacity * 0.5` alpha, i.e. under 1% here) and the overlay renders
  /// nothing.
  ///
  /// This is a correctness guard, not just an optimization: when visible the
  /// overlay installs a full-screen [HitTestBehavior.opaque] tap-catcher (to
  /// collapse the sheet), which sits directly above the map in `MapShell`.
  /// Kept alive at a sub-perceptual opacity it would silently swallow every
  /// map gesture — pan, pinch-zoom — leaving the map "frozen" until an
  /// unrelated interaction resets the opacity to 0. The threshold also
  /// absorbs the sub-snap residual the bottom sheet's drag-release velocity
  /// spring can strand just above its collapsed snap.
  static const double _kMinVisibleOpacity = 0.02;

  @override
  Widget build(BuildContext context) {
    if (opacity < _kMinVisibleOpacity) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        color: Colors.black.withValues(alpha: opacity * 0.5),
      ),
    );
  }
}
