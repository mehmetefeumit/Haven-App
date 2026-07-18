/// Combined "your profile is public" disclosure notice.
///
/// Public profiles are public-by-default and UNCONDITIONAL (owner-directed
/// 2026-07-16, matching the White Noise reference app): saving a display name
/// or photo always publishes it as a kind-0 Nostr event, visible to anyone on
/// the network — not just members of the user's circles. There is no
/// opt-in/consent toggle; this widget is the single, neutral disclosure of
/// that fact, shown in exactly two places (same widget, so the copy never
/// drifts):
/// - Onboarding's `CreateIdentityScreen` (`create_identity_screen.dart`), near
///   the pre-filled display-name field.
/// - The Identity settings page (`identity_page.dart`), adjacent to the photo
///   header and the display-name card — the two editable fields the notice
///   describes.
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A neutral (informational, not a warning) callout disclosing that the
/// user's public profile (display name + photo) is visible to anyone on the
/// Nostr network.
///
/// Deliberately has no dismiss/toggle action — it is a standing disclosure,
/// not a one-time prompt. Exposes its title and body as a single [Semantics]
/// block so a screen reader announces them together, in reading order, and
/// mirrors the app's existing compact "explainer box" styling (see
/// `qr_code_page.dart` / `location_settings_page.dart`).
class PublicProfileNotice extends StatelessWidget {
  /// Creates a [PublicProfileNotice].
  const PublicProfileNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final title = l10n.profileIsPublicNoticeTitle;
    final body = l10n.profileIsPublicNoticeBody;

    return Semantics(
      // Read as one block ("Profile is public. <body>") rather than two
      // separate nodes, so a screen reader announces the disclosure as a
      // single coherent statement.
      label: '$title. $body',
      container: true,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(HavenSpacing.md),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(HavenSpacing.sm),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.info,
                  size: 16,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            const SizedBox(height: HavenSpacing.sm),
            Text(
              body,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
