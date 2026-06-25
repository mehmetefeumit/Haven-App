/// Trailing disclosure chevron for navigable list rows.
///
/// Mirrors under right-to-left text direction. The Lucide chevron is not a
/// Material directional icon, so it does NOT auto-flip the way a Material
/// `Icons.chevron_right` would — this widget picks the correct glyph from the
/// ambient [Directionality]. Use it for every "opens a sub-page" affordance so
/// RTL builds (e.g. Arabic) point the arrow toward the end edge, not backwards.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A disclosure chevron that points toward the end edge in both LTR and RTL.
class DisclosureChevron extends StatelessWidget {
  /// Creates a disclosure chevron.
  const DisclosureChevron({super.key, this.color});

  /// Optional icon colour; defaults to the ambient [IconTheme].
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final pointsLeft = Directionality.of(context) == TextDirection.rtl;
    return Icon(
      pointsLeft ? LucideIcons.chevronLeft : LucideIcons.chevronRight,
      color: color,
    );
  }
}
