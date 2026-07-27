/// Shared informational callout box.
///
/// Unifies three implementations that had drifted apart: `PublicProfileNotice`
/// and the QR page's explainer both used `surfaceContainerLow` with a
/// [HavenSpacing.sm] radius, while the relay page's backend explainer used
/// `surfaceContainerHighest` with a hard-coded radius of 12. This widget
/// standardises on the former.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Visual tone of a [HavenInfoNote].
enum HavenInfoNoteTone {
  /// Neutral disclosure. The default: informational, not an alert.
  neutral,

  /// A limitation the user can act on. Tints only the icon and container —
  /// never the body text.
  warning,
}

/// Text density of a [HavenInfoNote].
enum HavenInfoNoteDensity {
  /// `bodySmall` (12sp). For short notes attached to a control.
  compact,

  /// `bodyMedium` (14sp). The floor for long-form reading content, where
  /// 12sp prose is too small to sustain.
  comfortable,
}

/// A callout box presenting one or more short paragraphs, optionally under a
/// title, in a tinted rounded container.
///
/// Tone is deliberately constrained. Haven's colour system promises that "a
/// green pixel always communicates security, never decoration", so
/// [HavenInfoNoteTone.warning] tints the icon and container background only:
/// `HavenSecurityColors.warning` measures 3.19:1 against a light surface, which
/// clears the 3:1 non-text threshold but fails the 4.5:1 required of body text.
/// Body text therefore always uses `onSurfaceVariant` (7.81:1).
///
/// [mergeSemantics] collapses the whole note into a single screen-reader node.
/// That is right for a two-line disclosure, which should be announced as one
/// coherent statement, and wrong for anything longer: a merged 200-word node
/// cannot be navigated, re-read a sentence at a time, or text-selected. Leave
/// it on for short notes; turn it off for reading content.
class HavenInfoNote extends StatelessWidget {
  /// Creates a [HavenInfoNote].
  const HavenInfoNote({
    required this.paragraphs,
    this.title,
    this.icon = LucideIcons.info,
    this.tone = HavenInfoNoteTone.neutral,
    this.density = HavenInfoNoteDensity.compact,
    this.mergeSemantics = true,
    super.key,
  });

  /// Body paragraphs, rendered in order with a [HavenSpacing.sm] gap between.
  final List<String> paragraphs;

  /// Optional heading shown beside [icon].
  final String? title;

  /// Leading icon. Defaults to an "info" glyph.
  final IconData icon;

  /// Visual tone. See [HavenInfoNoteTone].
  final HavenInfoNoteTone tone;

  /// Text density. See [HavenInfoNoteDensity].
  final HavenInfoNoteDensity density;

  /// Whether to announce the note as one screen-reader node.
  final bool mergeSemantics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isWarning = tone == HavenInfoNoteTone.warning;
    final iconColor = isWarning
        ? HavenSecurityColors.warning
        : scheme.onSurfaceVariant;
    final background = isWarning
        ? HavenSecurityColors.warning.withValues(alpha: 0.1)
        : scheme.surfaceContainerLow;
    final bodyStyle =
        (density == HavenInfoNoteDensity.compact
                ? theme.textTheme.bodySmall
                : theme.textTheme.bodyMedium)
            ?.copyWith(color: scheme.onSurfaceVariant);

    final content = Container(
      padding: const EdgeInsets.all(HavenSpacing.md),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(HavenSpacing.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Row(
              // Keeps the icon aligned to the first line of a title that wraps
              // at large text scales.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 16, color: iconColor),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(title!, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
          ],
          for (var i = 0; i < paragraphs.length; i++) ...[
            if (i > 0) const SizedBox(height: HavenSpacing.sm),
            Text(paragraphs[i], style: bodyStyle),
          ],
        ],
      ),
    );

    if (!mergeSemantics) return content;

    // "Title. Body" — the sentence break after the title is what makes a
    // screen reader pause between the heading and the disclosure rather than
    // running them together.
    final body = paragraphs.join(' ');
    return Semantics(
      label: title == null ? body : '$title. $body',
      container: true,
      excludeSemantics: true,
      child: content,
    );
  }
}
