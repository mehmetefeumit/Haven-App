/// Haven app mark widget.
///
/// Renders the bundled brand logo on a circular white tile so it stays
/// legible on every surface and mirrors the installed launcher icon.
library;

import 'package:flutter/material.dart';

/// The Haven logo, presented as a circular white app-icon tile.
///
/// The brand mark (a black house-shaped "h" with a red accent) lives in
/// [assetPath] on a transparent background, so it is always shown on white —
/// a dark tile would swallow the black mark. This keeps it legible in both
/// light and dark themes and makes the in-app branding match the launcher
/// icon generated from the same master image. Used as the onboarding hero
/// mark and in the About page header.
class HavenLogo extends StatelessWidget {
  /// Creates a Haven logo tile of the given [size].
  const HavenLogo({super.key, this.size = 120});

  /// Bundled asset path of the master brand mark.
  ///
  /// This is the same 1024×1024 image that the launcher/store icons are
  /// generated from (see `flutter_launcher_icons` in `pubspec.yaml`).
  static const String assetPath = 'assets/icon/icon.png';

  /// Width and height of the circular tile, in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      // The master carries its own margin; a little extra keeps the mark
      // clear of the circular edge without shrinking it too far.
      padding: EdgeInsets.all(size * 0.12),
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Image.asset(
        assetPath,
        fit: BoxFit.contain,
        semanticLabel: 'Haven logo',
      ),
    );
  }
}
