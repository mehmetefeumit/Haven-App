/// Direction-aware back/forward arrows for navigation affordances.
///
/// Lucide icons are not Material directional icons, so they do NOT auto-flip
/// under right-to-left text direction the way `Icons.arrow_back` would. These
/// widgets pick the correct glyph from the ambient [Directionality] (the same
/// approach as `DisclosureChevron`), so that in RTL builds (Arabic, Persian,
/// Urdu) a "back" arrow points right and a "forward" arrow points left.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// An arrow pointing toward the "previous"/back direction in both LTR and RTL.
///
/// Points left in LTR and right in RTL. Use for back-navigation affordances
/// instead of a hardcoded `LucideIcons.arrowLeft`.
class BackArrow extends StatelessWidget {
  /// Creates a direction-aware back arrow.
  const BackArrow({super.key, this.color, this.size});

  /// Optional icon colour; defaults to the ambient [IconTheme].
  final Color? color;

  /// Optional icon size; defaults to the ambient [IconTheme].
  final double? size;

  @override
  Widget build(BuildContext context) {
    final pointsRight = Directionality.of(context) == TextDirection.rtl;
    return Icon(
      pointsRight ? LucideIcons.arrowRight : LucideIcons.arrowLeft,
      color: color,
      size: size,
    );
  }
}

/// An arrow pointing toward the "next"/forward direction in both LTR and RTL.
///
/// Points right in LTR and left in RTL. Use for forward/proceed affordances
/// instead of a hardcoded `LucideIcons.arrowRight`.
class ForwardArrow extends StatelessWidget {
  /// Creates a direction-aware forward arrow.
  const ForwardArrow({super.key, this.color, this.size});

  /// Optional icon colour; defaults to the ambient [IconTheme].
  final Color? color;

  /// Optional icon size; defaults to the ambient [IconTheme].
  final double? size;

  @override
  Widget build(BuildContext context) {
    final pointsLeft = Directionality.of(context) == TextDirection.rtl;
    return Icon(
      pointsLeft ? LucideIcons.arrowLeft : LucideIcons.arrowRight,
      color: color,
      size: size,
    );
  }
}
