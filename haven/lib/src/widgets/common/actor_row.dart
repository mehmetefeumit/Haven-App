/// Shared "actor: what they can observe" bullet row.
///
/// Extracted from `about_page.dart`'s `_WhoCanSeeWhat` so the Privacy page and
/// any other who-can-see-what disclosure render the same shape. A hanging
/// bullet is used deliberately in place of a table: a multi-column comparison
/// is unreadable at 360dp with 200% text scaling, forces horizontal scrolling
/// (a WCAG 1.4.10 reflow failure), and Flutter's table widgets expose no
/// row/column header association to screen readers.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A single actor row: the party's name in bold, followed by a plain-language
/// summary of what they can observe.
///
/// Renders as a hanging bullet so the summary wraps under itself rather than
/// under the bullet. The bullet is a separate leading widget with an explicit
/// [HavenSpacing] gap rather than literal padding spaces, so the gap stays a
/// fixed width across fonts and text scales.
class HavenActorRow extends StatelessWidget {
  /// Creates a [HavenActorRow].
  const HavenActorRow({required this.who, required this.sees, super.key});

  /// The party being described (e.g. "Relay operators").
  final String who;

  /// Plain-language summary of what [who] can observe.
  final String sees;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: HavenSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('•', style: bodyStyle),
          const SizedBox(width: HavenSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: bodyStyle,
                children: [
                  TextSpan(
                    text: who,
                    style: bodyStyle?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: ': $sees'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
