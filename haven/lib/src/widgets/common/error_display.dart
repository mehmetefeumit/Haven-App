/// Error display widget for Haven.
///
/// Provides consistent error states with retry functionality.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// Displays an error message with an optional retry button.
///
/// Use this widget for error states that can potentially be recovered
/// by retrying the failed operation.
class HavenErrorDisplay extends StatelessWidget {
  /// Creates an error display.
  ///
  /// The [message] is required. The [onRetry] callback, if provided,
  /// enables a retry button.
  const HavenErrorDisplay({
    required this.message,
    super.key,
    this.title,
    this.icon,
    this.onRetry,
  });

  /// The error message to display.
  final String message;

  /// Optional title above the message.
  final String? title;

  /// Optional custom icon. Defaults to an error icon.
  final IconData? icon;

  /// Callback when the retry button is pressed.
  ///
  /// If null, no retry button is shown.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.error_outline,
              size: 48,
              color: colorScheme.error,
            ),
            const SizedBox(height: HavenSpacing.base),
            if (title != null) ...[
              Text(
                title!,
                style: Theme.of(context).textTheme.titleMedium,
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
            if (onRetry != null) ...[
              const SizedBox(height: HavenSpacing.lg),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact error card for inline error display.
///
/// Use this for errors within a larger UI, not as a full-page state.
class HavenErrorCard extends StatelessWidget {
  /// Creates an error card.
  const HavenErrorCard({required this.message, super.key, this.onDismiss});

  /// The error message to display.
  final String message;

  /// Callback when the dismiss button is pressed.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: colorScheme.onErrorContainer),
            const SizedBox(width: HavenSpacing.md),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colorScheme.onErrorContainer),
              ),
            ),
            if (onDismiss != null)
              IconButton(
                icon: Icon(Icons.close, color: colorScheme.onErrorContainer),
                onPressed: onDismiss,
                tooltip: 'Dismiss',
              ),
          ],
        ),
      ),
    );
  }
}
