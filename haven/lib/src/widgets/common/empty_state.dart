/// Empty state widget for Haven.
///
/// Provides consistent empty states with call-to-action buttons.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Displays an empty state with icon, message, and optional action.
///
/// Use this widget when a list or content area has no items to display.
class HavenEmptyState extends StatelessWidget {
  /// Creates an empty state display.
  const HavenEmptyState({
    required this.message,
    super.key,
    this.title,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.actionKey,
  });

  /// The main message explaining why the state is empty.
  final String message;

  /// Optional title above the message.
  final String? title;

  /// Icon to display. Defaults to an inbox icon.
  final IconData? icon;

  /// Label for the action button.
  final String? actionLabel;

  /// Callback when the action button is pressed.
  ///
  /// If null, no action button is shown.
  final VoidCallback? onAction;

  /// Optional stable [Key] applied to the action button.
  ///
  /// Lets callers wire a known widget key (e.g. one from
  /// `lib/src/test_keys.dart`) so E2E tests can target the CTA without
  /// relying on its label text.
  final Key? actionKey;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? LucideIcons.inbox,
              size: 64,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: HavenSpacing.lg),
            if (title != null) ...[
              Text(
                title!,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: HavenSpacing.sm),
            ],
            Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: HavenSpacing.lg),
              FilledButton.icon(
                key: actionKey,
                onPressed: onAction,
                icon: const Icon(LucideIcons.plus),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
