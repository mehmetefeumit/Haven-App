/// In-app location prominent-disclosure dialog.
///
/// Satisfies Google Play's "Prominent Disclosure & Consent" requirement: an
/// affirmative, in-app disclosure of WHY/WHAT/HOW location is used, shown
/// BEFORE the OS runtime permission prompt. It does not itself request any
/// permission; it only records the user's informed consent.
///
/// Its copy is the `locationDisclosure*` group in `haven/lib/l10n/app_en.arb`,
/// where each `@description` records the constraint that governs its sentence —
/// what a Prominent Disclosure must name, which claim is true on which
/// platform, and which wording was false before. Consent a user cannot read is
/// not informed consent, so this artefact is localized like every other screen;
/// do not reintroduce hard-coded copy here.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';

/// A modal disclosure dialog returning the user's consent decision.
///
/// Use [show]; it returns `true` only on affirmative consent. The dialog is
/// non-dismissible (no barrier tap / back dismissal counts as consent) and
/// deliberately does NOT mimic the Android system permission sheet.
class LocationDisclosureDialog extends StatelessWidget {
  const LocationDisclosureDialog._({
    required this.includeBackground,
    required this.isIOS,
  });

  /// Whether to include the background-collection disclosure sentence.
  final bool includeBackground;

  /// Whether the running platform is iOS, selecting the accurate background
  /// sentence. Read from `Platform.isIOS` in production, not from
  /// `Theme.of(context).platform`, which is a styling knob an app may override
  /// and so must not decide what a consent artefact claims.
  final bool isIOS;

  /// Shows the disclosure dialog and resolves to the consent decision.
  ///
  /// Returns `true` only when the user taps "Agree"; any other dismissal
  /// (including the back button) resolves to `false`. [isIOS] is a test seam
  /// over `Platform.isIOS` (same idiom as `geolocator_location_service.dart`).
  static Future<bool> show(
    BuildContext context, {
    required bool includeBackground,
    bool? isIOS,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => LocationDisclosureDialog._(
        includeBackground: includeBackground,
        isIOS: isIOS ?? Platform.isIOS,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return PopScope(
      // A back gesture must not count as consent; treat it as "Not now".
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: AlertDialog(
        title: Text(l10n.locationDisclosureTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.locationDisclosureWhy,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: HavenSpacing.base),
              Text(
                l10n.locationDisclosureHow,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: HavenSpacing.base),
              Text(
                l10n.locationDisclosureSharing,
                style: theme.textTheme.bodyMedium,
              ),
              if (includeBackground) ...[
                const SizedBox(height: HavenSpacing.base),
                Text(
                  isIOS
                      ? l10n.locationDisclosureBackgroundIos
                      : l10n.locationDisclosureBackgroundAndroid,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  l10n.locationDisclosureManage,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: WidgetKeys.locationDisclosureNotNow,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.locationDisclosureNotNow),
          ),
          FilledButton(
            key: WidgetKeys.locationDisclosureAgree,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.locationDisclosureAgree),
          ),
        ],
      ),
    );
  }
}
