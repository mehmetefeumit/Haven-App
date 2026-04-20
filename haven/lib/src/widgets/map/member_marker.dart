/// Member marker widget for Haven map.
///
/// Displays a circle member's location with avatar and an age pill showing
/// how long ago the data was recorded.
library;

import 'dart:math' show max;

import 'package:flutter/material.dart';

/// Formats a [Duration] into a compact age string for the visible pill.
///
/// Branches:
/// - `< 1 minute` → `"just now"`
/// - `< 60 minutes` → `"Xm"`
/// - `< 24 hours` → `"Xh"`
/// - `≥ 24 hours` → `"Xd"`
String _formatAge(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m';
  if (age.inHours < 24) return '${age.inHours}h';
  return '${age.inDays}d';
}

/// Formats a [Duration] into an expanded age string for screen readers.
///
/// Screen readers pronounce "5m" as "five em" and "2h" as "two aitch"; the
/// expanded form reads naturally via VoiceOver/TalkBack. Singular units are
/// handled separately so speech is grammatical ("1 minute ago", not
/// "1 minutes ago").
String _formatAgeForSemantics(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) {
    return age.inMinutes == 1 ? '1 minute ago' : '${age.inMinutes} minutes ago';
  }
  if (age.inHours < 24) {
    return age.inHours == 1 ? '1 hour ago' : '${age.inHours} hours ago';
  }
  return age.inDays == 1 ? '1 day ago' : '${age.inDays} days ago';
}

/// A marker showing a circle member's location on the map.
///
/// Features:
/// - Avatar display with initials fallback
/// - Neutral outline ring (same color regardless of data age)
/// - Age pill in the bottom-right corner showing time since last update
/// - Minimum 48dp touch target for accessibility
class MemberMarker extends StatelessWidget {
  /// Creates a member marker.
  const MemberMarker({
    required this.initials,
    super.key,
    this.imageUrl,
    this.publicKey,
    this.size = 44,
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

  /// Timestamp the location was originally recorded.
  ///
  /// Used to compute the age pill label ("5m", "2h", etc.). When null,
  /// no pill is rendered.
  final DateTime? lastSeen;

  /// Callback when the marker is tapped.
  final VoidCallback? onTap;

  Color _generateAvatarColor() {
    if (publicKey == null || publicKey!.isEmpty) {
      return Colors.grey;
    }
    final hash = publicKey.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    // Ensure minimum 48dp touch target for accessibility.
    final touchTargetSize = max<double>(size + 8, 48);

    // Compute age once per build so the visible pill and the screen-reader
    // label cannot drift across a minute boundary.
    final age = lastSeen != null ? DateTime.now().difference(lastSeen!) : null;
    final agePillLabel = age != null ? _formatAge(age) : null;
    final semanticsLabel = age != null
        ? '$initials member marker, last seen ${_formatAgeForSemantics(age)}'
        : '$initials member marker';

    // Cap the user's text scaling for the pill so Dynamic Type cannot blow
    // the label out of the 56×56 marker footprint. 1.3× still benefits
    // low-vision users without breaking layout.
    final pillTextScaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: 1.3);

    final markerBody = SizedBox(
      width: size + 8,
      height: size + 8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Neutral outline ring — identical appearance regardless of data age.
          Container(
            width: size + 8,
            height: size + 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: colorScheme.outline, width: 3),
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

          // Age pill — always rendered when lastSeen is non-null. The drop
          // shadow + stronger `outline` border keep the pill legible over
          // arbitrary OSM tile colors, where `outlineVariant` alone could
          // fade into matching map regions.
          if (agePillLabel != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colorScheme.outline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  agePillLabel,
                  textScaler: pillTextScaler,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onSurfaceVariant,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    // `excludeSemantics: true` prevents the visible initials Text and the
    // age pill Text from being appended to the authored label. Both are
    // already conveyed in `semanticsLabel`, so without this screen readers
    // would announce "<initials> member marker, last seen X. <initials>. X"
    // — redundant and confusing.
    return Semantics(
      label: semanticsLabel,
      button: onTap != null,
      excludeSemantics: true,
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
