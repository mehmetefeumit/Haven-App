/// The circular save button that sits to the right of a single-field editor.
///
/// Shared by the display-name card and the member nickname editor so the two
/// save affordances can never drift apart.
library;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Edit state of a single-field editor, as carried by [CircularSaveButton].
enum SaveStatus {
  /// The field matches the persisted value.
  saved,

  /// The field has been edited but not yet saved.
  unsaved,

  /// A save is in flight.
  saving,

  /// The most recent save attempt failed.
  failed,
}

/// Compact 48dp circular save button.
///
/// Encodes [status] through its icon (a distinct shape per state, so the
/// signal is never color-only) and carries a per-state tooltip/accessible
/// label. Kept a [FilledButton] so it inherits the M3 state layer, focus ring,
/// and disabled treatment, and stays a [ButtonStyleButton]. The spinner is
/// rendered inside the button while a save is in flight.
class CircularSaveButton extends StatelessWidget {
  /// Creates a circular save button.
  const CircularSaveButton({
    required this.buttonKey,
    required this.status,
    required this.onPressed,
    required this.savedLabel,
    required this.saveLabel,
    required this.savingLabel,
    required this.retryLabel,
    super.key,
  });

  /// Key placed on the inner [FilledButton], so callers' tests find a
  /// [ButtonStyleButton] whatever the current icon.
  final Key buttonKey;

  /// The state the icon, colours and label show.
  final SaveStatus status;

  /// Save action; `null` disables the button.
  final VoidCallback? onPressed;

  /// Tooltip and accessible label for [SaveStatus.saved].
  final String savedLabel;

  /// Tooltip and accessible label for [SaveStatus.unsaved].
  final String saveLabel;

  /// Tooltip and accessible label for [SaveStatus.saving].
  final String savingLabel;

  /// Tooltip and accessible label for [SaveStatus.failed].
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    final (
      Widget child,
      String label,
      Color? background,
      Color? foreground,
    ) = switch (status) {
      SaveStatus.saved => (
        const Icon(LucideIcons.check, size: 20),
        savedLabel,
        null,
        null,
      ),
      SaveStatus.unsaved => (
        const Icon(LucideIcons.arrowUp, size: 20),
        saveLabel,
        null,
        null,
      ),
      SaveStatus.saving => (
        SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: colorScheme.onPrimary,
          ),
        ),
        savingLabel,
        null,
        null,
      ),
      SaveStatus.failed => (
        const Icon(LucideIcons.rotateCcw, size: 20),
        retryLabel,
        colorScheme.errorContainer,
        colorScheme.onErrorContainer,
      ),
    };

    final animatedChild = reducedMotion
        ? child
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, animation) =>
                ScaleTransition(scale: animation, child: c),
            child: KeyedSubtree(
              key: ValueKey<SaveStatus>(status),
              child: child,
            ),
          );

    return Tooltip(
      message: label,
      child: FilledButton(
        key: buttonKey,
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          minimumSize: const Size(48, 48),
          fixedSize: const Size(48, 48),
          backgroundColor: background,
          foregroundColor: foreground,
        ),
        // Give the icon-only button a state-dependent accessible name. There
        // is no live region here; screen readers read this label when the
        // button is focused, and the caller announces save outcomes.
        child: Semantics(
          label: label,
          excludeSemantics: true,
          child: animatedChild,
        ),
      ),
    );
  }
}
