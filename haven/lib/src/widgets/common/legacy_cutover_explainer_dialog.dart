/// One-time Dark Matter cutover explainer dialog (DM-4c, plan §6 step 2).
library;

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/theme/theme.dart';

/// Shows the one-time explainer that runs the first time `MapShell` mounts
/// after the Dark Matter cutover destroyed the legacy MLS database.
///
/// Explains, in plain language, that the user's identity and public profile
/// are unchanged, but every circle must be re-created and its members
/// re-invited (the old encrypted-group state cannot be carried forward — see
/// `docs/MDK_DARKMATTER_MIGRATION_PLAN.md` §6). Purely informational: it
/// gathers no consent and gates no permission, so a single acknowledgement
/// action is enough.
class LegacyCutoverExplainerDialog extends StatelessWidget {
  const LegacyCutoverExplainerDialog._();

  /// Shows the dialog. Resolves once the user dismisses it.
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const LegacyCutoverExplainerDialog._(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(l10n.legacyCutoverExplainerTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.legacyCutoverExplainerIdentityUnchanged,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: HavenSpacing.base),
            Text(
              l10n.legacyCutoverExplainerCirclesNeedRecreation,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.legacyCutoverExplainerAcknowledge),
        ),
      ],
    );
  }
}
