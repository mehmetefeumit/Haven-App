/// User location marker widget for Haven map.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/widgets/map/member_marker.dart' show kMarkerKeyline;

/// A marker showing the user's current location on the map.
///
/// A static dot: an 18 dp core, a 3 dp white ring and a 1 px keyline, 26 dp
/// in all. Achromatic because green means "sharing" in this design system and
/// the dot shows on any fix; constant ink, never a `ColorScheme` token,
/// because the basemap is chosen independently of the theme.
class UserLocationMarker extends StatelessWidget {
  /// Creates a user location marker.
  const UserLocationMarker({super.key});

  static const Color _core = Color(0xFF0A0A0A);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      label: l10n.userLocationMarkerSemantics,
      // `Center` frees the dot from the tight box a `Marker` imposes.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: SizedBox.square(
          dimension: 26,
          // A `Container`, not a `DecoratedBox`: only it insets the child by
          // the keyline's width, which keeps the ring at 24 dp.
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: kMarkerKeyline),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _core,
                border: Border.all(color: Colors.white, width: 3),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
