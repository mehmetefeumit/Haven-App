/// Shared list-section header.
///
/// Extracted from `appearance_settings_page.dart` so every settings-style
/// section header carries the same styling *and* the same screen-reader
/// heading semantics. Centralising it is what makes it structurally impossible
/// to ship a section title that a screen reader cannot navigate to.
library;

import 'package:flutter/material.dart';

/// A list-section header styled per Material 3, exposed as a semantic header so
/// screen readers can navigate by heading.
///
/// [headingLevel] maps to the platform heading level (1-6) that assistive
/// technology uses to build its heading outline; leaving it null keeps the
/// framework default of an unlevelled header. On long-form reading pages the
/// levels matter — they are what makes TalkBack's Headings reading control and
/// the VoiceOver rotor jump between sections instead of traversing every line.
class HavenSectionHeader extends StatelessWidget {
  /// Creates a [HavenSectionHeader].
  const HavenSectionHeader({
    required this.label,
    this.headingLevel,
    super.key,
  });

  /// The header text.
  final String label;

  /// Assistive-technology heading level. Null means "a header, unlevelled";
  /// otherwise [Semantics] requires a value from 1 to 6.
  final int? headingLevel;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 8),
      child: Semantics(
        header: true,
        headingLevel: headingLevel,
        child: Text(
          label,
          style: textTheme.labelLarge?.copyWith(color: colorScheme.primary),
        ),
      ),
    );
  }
}
