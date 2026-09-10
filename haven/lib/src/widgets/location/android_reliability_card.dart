/// Android's OS-level reliability guidance for background location sharing.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Android-only card telling the user which OS settings keep background
/// sharing alive (notification, battery optimization, OEM app killers).
///
/// A widget rather than a method on `LocationSettingsPage` so its layout can
/// be rendered and asserted on the Linux test host: the page gates it behind
/// `Platform.isAndroid`, which a widget test cannot override, and the heading
/// below is exactly the kind of text that clips silently on a real phone
/// without anyone seeing it in a test.
class AndroidReliabilityCard extends StatelessWidget {
  /// Creates an [AndroidReliabilityCard].
  const AndroidReliabilityCard({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.base),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              // Keeps the icon beside the FIRST line once the heading wraps.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  LucideIcons.info,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Semantics(
                    header: true,
                    // The heading WRAPS. It used to be clamped to one
                    // ellipsized line, which fits ~34 characters at the
                    // default text scale in the ~260 dp this card leaves on a
                    // 360 dp phone — less than the shipped pt (49), tr (42),
                    // es (41) and de (39) headings need, and less than every
                    // locale needs at a 200 % text scale. Nothing here
                    // competes for the vertical space a second line takes.
                    child: Text(
                      l10n.locationSettingsAndroidHeader,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              l10n.locationSettingsAndroidNotification,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              l10n.locationSettingsAndroidBattery,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              l10n.locationSettingsAndroidVendors,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
