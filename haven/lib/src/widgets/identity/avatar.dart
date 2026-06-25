/// Avatar widget for Haven.
///
/// Displays user avatars with fallback to initials or identicon.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:haven/src/widgets/map/marker_metrics.dart';

/// A circular avatar for displaying user identity.
///
/// Shows the user's image if available, otherwise falls back to
/// initials or a generated color based on their public key.
///
/// Security note: images are displayed from local bytes only
/// ([imageBytes]) — never via a network URL — so no avatar data is
/// leaked to relays or CDNs.
class HavenAvatar extends StatelessWidget {
  /// Creates an avatar widget.
  ///
  /// At least one of [imageBytes], [initials], or [publicKey] should
  /// be provided for meaningful display.
  const HavenAvatar({
    super.key,
    this.imageBytes,
    this.initials,
    this.publicKey,
    this.size = HavenAvatarSize.medium,
    this.diameter,
    this.showOnlineIndicator = false,
    this.isOnline = false,
  });

  /// Raw JPEG/PNG/WebP bytes for the avatar image.
  ///
  /// When non-null and non-empty the image is rendered via
  /// [Image.memory] (never [Image.network]).  Falls back to initials
  /// on decode error.
  final Uint8List? imageBytes;

  /// Initials to display as fallback (1-2 characters).
  final String? initials;

  /// Public key for generating consistent fallback color.
  final String? publicKey;

  /// Size of the avatar.
  ///
  /// Ignored when [diameter] is provided.
  final HavenAvatarSize size;

  /// Explicit diameter in logical pixels, overriding [size].
  ///
  /// Lets a caller match a sibling widget's dimensions exactly — e.g. a
  /// Material [CircleAvatar] rendered next to a [HavenAvatar] in the same
  /// list, where the two must be the same size. The fallback-initials font
  /// and the online-status indicator scale proportionally with the diameter
  /// so the avatar stays visually balanced at any custom size.
  ///
  /// Those proportional values are approximations: they will not exactly
  /// reproduce the individually tuned font/indicator sizes of [size] even
  /// when the diameter matches an enum step. Use [size] when you want the
  /// tuned values; use [diameter] when matching a sibling's pixel size wins.
  final double? diameter;

  /// Whether to show the online status indicator.
  final bool showOnlineIndicator;

  /// Whether the user is currently online.
  final bool isOnline;

  @override
  Widget build(BuildContext context) {
    final resolvedDiameter =
        diameter ??
        switch (size) {
          HavenAvatarSize.small => 32.0,
          HavenAvatarSize.medium => 48.0,
          HavenAvatarSize.large => 64.0,
          HavenAvatarSize.xlarge => 96.0,
        };

    // When an explicit diameter overrides the size enum, derive the fallback
    // font and status indicator proportionally from it so the avatar stays
    // balanced. Otherwise use the size enum's individually tuned values.
    final fontSize = diameter != null
        ? resolvedDiameter * 0.375
        : switch (size) {
            HavenAvatarSize.small => 12.0,
            HavenAvatarSize.medium => 16.0,
            HavenAvatarSize.large => 24.0,
            HavenAvatarSize.xlarge => 36.0,
          };

    final indicatorSize = diameter != null
        ? resolvedDiameter * 0.25
        : switch (size) {
            HavenAvatarSize.small => 8.0,
            HavenAvatarSize.medium => 12.0,
            HavenAvatarSize.large => 16.0,
            HavenAvatarSize.xlarge => 20.0,
          };

    final backgroundColor = _generateColor(
      publicKey,
      Theme.of(context).colorScheme,
    );

    Widget avatar = Container(
      width: resolvedDiameter,
      height: resolvedDiameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: backgroundColor,
      ),
      child: _buildContent(context, fontSize, backgroundColor),
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
                    ? HavenStatusColors.online
                    : HavenStatusColors.offline,
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

  Widget _buildContent(
    BuildContext context,
    double fontSize,
    Color backgroundColor,
  ) {
    final bytes = imageBytes;
    if (bytes != null && bytes.isNotEmpty) {
      return ClipOval(
        child: Image.memory(
          bytes,
          gaplessPlayback: true,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return _buildFallback(context, fontSize, backgroundColor);
          },
        ),
      );
    }

    return _buildFallback(context, fontSize, backgroundColor);
  }

  Widget _buildFallback(
    BuildContext context,
    double fontSize,
    Color backgroundColor,
  ) {
    final displayInitials = initials == null
        ? '?'
        : initials!.toUpperCase().characters.take(2).string;

    return Center(
      child: Text(
        displayInitials,
        style: TextStyle(
          color: _onColor(backgroundColor),
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Color _generateColor(String? key, ColorScheme scheme) {
    if (key == null || key.isEmpty) {
      return scheme.surfaceContainerHigh;
    }

    // Desaturated HSL hue derived from the pubkey. Saturation kept low so
    // the avatar reads as a quiet identifier, not louder than the chrome.
    final hash = key.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor();
  }

  /// Picks the max-contrast foreground (black or white) against [bg].
  ///
  /// Delegates to [onAvatarColor] from `marker_metrics.dart`, which
  /// picks by WCAG contrast ratio rather than a luminance threshold —
  /// guaranteeing ≥ 4.5:1 (WCAG AA) across every hue at the avatar's
  /// saturation/lightness point, including mid-luminance tones where a
  /// simple >0.5 threshold would pass only ~2:1.
  Color _onColor(Color bg) => onAvatarColor(bg);

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
