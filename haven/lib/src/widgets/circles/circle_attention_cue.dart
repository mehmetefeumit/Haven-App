/// The non-text "needs attention" cue on a circle: a badge, with an
/// accessible name, that opens the circle's details in one tap.
///
/// It carries no message of its own (OD-1): the sharing card and the change
/// card in Circle details say what is wrong; this only says there is
/// something to read there, so a closed sheet does not hide a fault.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A 48 dp button showing an error-coloured badge on an alert glyph.
class CircleAttentionCue extends StatelessWidget {
  /// Creates the cue; [onPressed] opens the circle's details.
  const CircleAttentionCue({required this.onPressed, super.key});

  /// Opens the circle's details.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: AppLocalizations.of(context).circleDetailsAttentionTooltip,
      onPressed: onPressed,
      icon: Badge(
        smallSize: 10,
        // `error` clears 3:1 against both the sheet surface and the selector
        // panel in both themes (WCAG 2.1 SC 1.4.11; circle_attention_cue_test).
        backgroundColor: scheme.error,
        // Not the details button's `info` glyph: on the header this stands in
        // its place, and a cue for another circle can sit on screen with it;
        // the two must not read as one control.
        child: Icon(
          LucideIcons.triangleAlert,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
