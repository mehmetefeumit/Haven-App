/// Loading indicator widget for Haven.
///
/// Provides a consistent loading experience throughout the app
/// with optional label text.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';

/// A centered loading indicator with optional label.
///
/// Use this widget to show loading states consistently across the app.
class HavenLoadingIndicator extends StatelessWidget {
  /// Creates a loading indicator.
  ///
  /// The [label] parameter optionally displays text below the spinner.
  const HavenLoadingIndicator({super.key, this.label});

  /// Optional label to display below the loading spinner.
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: HavenSpacing.base),
            Text(
              label!,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A small inline loading spinner for button states.
///
/// Use this inside buttons to indicate loading without changing button size.
class HavenButtonSpinner extends StatelessWidget {
  /// Creates a button-sized spinner.
  const HavenButtonSpinner({super.key});

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 20,
      height: 20,
      child: CircularProgressIndicator(strokeWidth: 2),
    );
  }
}
