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

  @override
  Widget build(BuildContext context) {
    // Ensure minimum 48dp touch target for accessibility
    final touchTargetSize = max<double>(size + 8, 48);

    return Semantics(
      label: '$initials member marker, $_freshnessLabel',
      button: onTap != null,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: touchTargetSize,
          height: touchTargetSize,
          child: Center(
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
                      border: Border.all(color: _freshnessColor, width: 3),
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

                  // Tap indicator for touch targets
                  if (onTap != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Theme.of(context).colorScheme.surface,
                          border: Border.all(
                            color: _freshnessColor,
                            width: 1.5,
                          ),
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
          ),
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
