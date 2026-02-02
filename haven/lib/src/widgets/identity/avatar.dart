/// Avatar widget for Haven.
///
/// Displays user avatars with fallback to initials or identicon.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A circular avatar for displaying user identity.
///
/// Shows the user's image if available, otherwise falls back to
/// initials or a generated color based on their public key.
class HavenAvatar extends StatelessWidget {
  /// Creates an avatar widget.
  ///
  /// At least one of [imageUrl], [initials], or [publicKey] should be
  /// provided for meaningful display.
  const HavenAvatar({
    super.key,
    this.imageUrl,
    this.initials,
    this.publicKey,
    this.size = HavenAvatarSize.medium,
    this.showOnlineIndicator = false,
    this.isOnline = false,
  });

  /// URL of the user's profile image.
  final String? imageUrl;

  /// Initials to display as fallback (1-2 characters).
  final String? initials;

  /// Public key for generating consistent fallback color.
  final String? publicKey;

  /// Size of the avatar.
  final HavenAvatarSize size;

  /// Whether to show the online status indicator.
  final bool showOnlineIndicator;

  /// Whether the user is currently online.
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final diameter = switch (size) {
      HavenAvatarSize.small => 32.0,
      HavenAvatarSize.medium => 48.0,
      HavenAvatarSize.large => 64.0,
      HavenAvatarSize.xlarge => 96.0,
    };

    final fontSize = switch (size) {
      HavenAvatarSize.small => 12.0,
      HavenAvatarSize.medium => 16.0,
      HavenAvatarSize.large => 24.0,
      HavenAvatarSize.xlarge => 36.0,
    };

    final indicatorSize = switch (size) {
      HavenAvatarSize.small => 8.0,
      HavenAvatarSize.medium => 12.0,
      HavenAvatarSize.large => 16.0,
      HavenAvatarSize.xlarge => 20.0,
    };

    final backgroundColor = _generateColor(publicKey);

    Widget avatar = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(shape: BoxShape.circle, color: backgroundColor),
      child: _buildContent(context, fontSize),
    );

    if (showOnlineIndicator) {
      avatar = Stack(
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: indicatorSize,
              height: indicatorSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isOnline
                    ? HavenFreshnessColors.live
                    : HavenFreshnessColors.old,
                border: Border.all(
                  color: Theme.of(context).colorScheme.surface,
                  width: 2,
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Semantics(label: _buildSemanticLabel(), child: avatar);
  }

  Widget _buildContent(BuildContext context, double fontSize) {
    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          imageUrl!,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallback(context, fontSize);
          },
        ),
      );
    }

    return _buildFallback(context, fontSize);
  }

  Widget _buildFallback(BuildContext context, double fontSize) {
    final displayInitials =
        initials?.toUpperCase().substring(
          0,
          initials!.length > 2 ? 2 : initials!.length,
        ) ??
        '?';

    return Center(
      child: Text(
        displayInitials,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _generateColor(String? key) {
    if (key == null || key.isEmpty) {
      return Colors.grey;
    }

    // Generate a consistent color from the public key hash
    final hash = key.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor();
  }

  String _buildSemanticLabel() {
    final parts = <String>['User avatar'];

    if (initials != null) {
      parts.add('for $initials');
    }

    if (showOnlineIndicator) {
      parts.add(isOnline ? 'online' : 'offline');
    }

    return parts.join(', ');
  }
}

/// Size variants for avatars.
enum HavenAvatarSize {
  /// Small avatar (32dp) for compact lists.
  small,

  /// Medium avatar (48dp) for standard use.
  medium,

  /// Large avatar (64dp) for profile headers.
  large,

  /// Extra large avatar (96dp) for prominent display.
  xlarge,
}
