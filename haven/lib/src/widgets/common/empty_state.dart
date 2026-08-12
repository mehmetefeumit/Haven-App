/// Empty state widget for Haven.
///
/// Provides consistent empty states with call-to-action buttons.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Visual weight of a [HavenEmptyState].
enum HavenEmptyStateDensity {
  /// Icon 48, `titleMedium`, no outer padding. For a placeholder occupying a
  /// region of a page that carries its own chrome.
  compact,

  /// Icon 64, `titleLarge`, `HavenSpacing.xl` padding. For a placeholder that
  /// is the whole screen.
  comfortable,
}

/// Displays an empty state with icon, message, and optional action.
///
/// Use this widget when a list or content area has no items to display.
///
/// The content is intrinsically sized and centred, so the HOST must give it a
/// min-height-with-unbounded-max slot — a `HavenScrollFill`, or a
/// `SliverFillRemaining(hasScrollBody: false)`. Handed a tight height instead,
/// it clips as soon as a wordier locale, a larger OS text scale or an open
/// keyboard eats the difference, and a clipped empty state tells the user
/// nothing at the one moment the screen has nothing else to say.
///
/// It stays plain rather than scrolling itself because both of those hosts
/// measure their child's intrinsic height, which no viewport or `LayoutBuilder`
/// can report.
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
    this.density = HavenEmptyStateDensity.comfortable,
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

  /// Visual weight. Defaults to [HavenEmptyStateDensity.comfortable].
  final HavenEmptyStateDensity density;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isCompact = density == HavenEmptyStateDensity.compact;

    return Padding(
      // Compact hosts already pad their own body; a second inset here would
      // only narrow the text measure.
      padding: EdgeInsets.all(isCompact ? 0 : HavenSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon ?? LucideIcons.inbox,
            size: isCompact ? 48 : 64,
            color: colorScheme.onSurfaceVariant,
          ),
          SizedBox(height: isCompact ? HavenSpacing.base : HavenSpacing.lg),
          if (title != null) ...[
            Text(
              title!,
              style: isCompact ? textTheme.titleMedium : textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HavenSpacing.sm),
          ],
          Text(
            message,
            style: textTheme.bodyMedium?.copyWith(
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
    );
  }
}
