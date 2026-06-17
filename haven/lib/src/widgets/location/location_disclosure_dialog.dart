/// In-app location prominent-disclosure dialog.
///
/// Satisfies Google Play's "Prominent Disclosure & Consent" requirement: an
/// affirmative, in-app disclosure of WHY/WHAT/HOW location is used, shown
/// BEFORE the OS runtime permission prompt. It does not itself request any
/// permission — it only records the user's informed consent.
library;

import 'package:flutter/material.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/theme/theme.dart';

/// User-facing copy for the location disclosure dialog.
///
/// Kept separate from the onboarding marketing copy: this is a compliance
/// disclosure that must be accurate and plain, so it uses the precise term
/// "end-to-end encrypted" (consistent with the iOS usage strings and the
/// privacy policy) rather than the softer onboarding phrasing.
abstract final class LocationDisclosureStrings {
  /// Dialog title.
  static const String title = 'Sharing your location';

  /// WHY + WHAT location is used (precise location, on the map).
  static const String why =
      'Haven shows your live location to the people in the circles you '
      'choose, and shows you theirs on the map. To do this, Haven needs '
      'permission to use your device’s precise location.';

  /// HOW the data is protected and who it is (and is not) shared with.
  static const String how =
      'Your location is end-to-end encrypted on your device. Only the '
      'members of the circles you choose can see it — never Haven, and '
      'never any other company.';

  /// Background-use sentence. Shown only when background sharing is being
  /// requested. Says "uses" rather than the Play sample's "collects": Haven
  /// transmits location only as end-to-end-encrypted messages and keeps no
  /// central copy, so "collects" would misstate what actually happens. (Mirrors
  /// the iOS `NSLocationAlwaysAndWhenInUseUsageDescription` wording, which also
  /// says "uses".)
  static const String background =
      'This app uses location data to enable sharing with your circles '
      'even when the app is closed or not in use.';

  /// Reassurance that the user stays in control. Shown only with the
  /// background scope (onboarding setup and the Settings toggle).
  static const String manage =
      'You can turn background sharing off at any time in '
      'Settings → Location.';

  /// Affirmative consent action.
  static const String agree = 'Agree';

  /// Decline action.
  static const String notNow = 'Not now';
}

/// A modal disclosure dialog returning the user's consent decision.
///
/// Use [show]; it returns `true` only on affirmative consent. The dialog is
/// non-dismissible (no barrier tap / back dismissal counts as consent) and
/// deliberately does NOT mimic the Android system permission sheet.
class LocationDisclosureDialog extends StatelessWidget {
  const LocationDisclosureDialog._({required this.includeBackground});

  /// Whether to include the background-collection disclosure sentence.
  final bool includeBackground;

  /// Shows the disclosure dialog and resolves to the consent decision.
  ///
  /// Returns `true` only when the user taps "Agree"; any other dismissal
  /// (including the back button) resolves to `false`.
  static Future<bool> show(
    BuildContext context, {
    required bool includeBackground,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          LocationDisclosureDialog._(includeBackground: includeBackground),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // A back gesture must not count as consent; treat it as "Not now".
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(false);
      },
      child: AlertDialog(
        title: const Text(LocationDisclosureStrings.title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                LocationDisclosureStrings.why,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: HavenSpacing.base),
              Text(
                LocationDisclosureStrings.how,
                style: theme.textTheme.bodyMedium,
              ),
              if (includeBackground) ...[
                const SizedBox(height: HavenSpacing.base),
                Text(
                  LocationDisclosureStrings.background,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: HavenSpacing.base),
                Text(
                  LocationDisclosureStrings.manage,
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
            child: const Text(LocationDisclosureStrings.notNow),
          ),
          FilledButton(
            key: WidgetKeys.locationDisclosureAgree,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(LocationDisclosureStrings.agree),
          ),
        ],
      ),
    );
  }
}
