/// Member marker widget for Haven map.
///
/// Displays a circle member's location with avatar and freshness indicator.
library;

import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/map/user_location_marker.dart';

/// A marker showing a circle member's location on the map.
///
/// Features:
/// - Avatar display with initials fallback
/// - Freshness ring indicating data age
/// - Tap callback for showing member details
/// - Minimum 48dp touch target for accessibility
class MemberMarker extends StatelessWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    super.key,
    this.imageUrl,
    this.publicKey,
    this.size = 44,
    this.freshness = LocationFreshness.live,
    this.isStale = false,
    this.lastSeen,
    this.onTap,
  });

  /// Initials to display (1-2 characters).
  final String initials;

  /// Optional profile image URL.
  final String? imageUrl;

  /// Public key for generating consistent avatar color.
  final String? publicKey;

  /// Size of the marker in logical pixels.
  final double size;

  /// How fresh the location data is.
  final LocationFreshness freshness;

  /// Whether this marker was hydrated from the persistent last-known
  /// location cache and has not yet been confirmed by a fresh relay
  /// event in the current session.
  ///
  /// Stale markers render with reduced opacity and a small clock badge
  /// to communicate that the position may not reflect the member's
  /// current location.
  final bool isStale;

  /// Timestamp the location was originally recorded.
  ///
  /// Used to produce the accessibility label ("Last seen 3h ago"). When
  /// null, no time suffix is shown.
  final DateTime? lastSeen;

  /// Callback when the marker is tapped.
  final VoidCallback? onTap;

  Color get _freshnessColor => switch (freshness) {
    LocationFreshness.live => HavenFreshnessColors.live,
    LocationFreshness.recent => HavenFreshnessColors.recent,
    LocationFreshness.stale => HavenFreshnessColors.stale,
    LocationFreshness.old => HavenFreshnessColors.old,
  };

  Color _generateAvatarColor() {
    if (publicKey == null || publicKey!.isEmpty) {
      return Colors.grey;
    }
    final hash = publicKey.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor();
  }

  String get _freshnessLabel => switch (freshness) {
    LocationFreshness.live => 'location live',
    LocationFreshness.recent => 'location recent',
    LocationFreshness.stale => 'location stale',
    LocationFreshness.old => 'location outdated',
  };

  String get _lastSeenLabel {
    if (lastSeen == null) return '';
    final age = DateTime.now().difference(lastSeen!);
    if (age.inMinutes < 1) return ', last seen just now';
    if (age.inMinutes < 60) return ', last seen ${age.inMinutes}m ago';
    if (age.inHours < 24) return ', last seen ${age.inHours}h ago';
    return ', last seen ${age.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    // Ensure minimum 48dp touch target for accessibility
    final touchTargetSize = max<double>(size + 8, 48);
    final staleSuffix = isStale ? ', stale$_lastSeenLabel' : '';

    final markerBody = Opacity(
      opacity: isStale ? 0.55 : 1.0,
      child: SizedBox(
        width: size + 8,
        height: size + 8,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Freshness ring
            Container(
              width: size + 8,
              height: size + 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _freshnessColor,
                  width: 3,
                  style: isStale ? BorderStyle.none : BorderStyle.solid,
                ),
              ),
            ),

            // Avatar
            Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _generateAvatarColor(),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _buildAvatarContent(context),
            ),

            // Stale badge — small clock icon in corner.
            if (isStale)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.surface,
                    border: Border.all(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    Icons.history,
                    size: 9,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            // Tap indicator for live markers with onTap handlers.
            else if (onTap != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.surface,
                    border: Border.all(color: _freshnessColor, width: 1.5),
                  ),
                  child: Icon(
                    Icons.info_outline,
                    size: 8,
                    color: _freshnessColor,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Semantics(
      label: '$initials member marker, $_freshnessLabel$staleSuffix',
      button: onTap != null,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: touchTargetSize,
          height: touchTargetSize,
          child: Center(child: markerBody),
        ),
      ),
    );
  }

  Widget _buildAvatarContent(BuildContext context) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildInitials(),
        ),
      );
    }
    return _buildInitials();
  }

  Widget _buildInitials() {
    final displayInitials = initials.toUpperCase().substring(
      0,
      initials.length > 2 ? 2 : initials.length,
    );

    return Center(
      child: Text(
        displayInitials,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.35,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
