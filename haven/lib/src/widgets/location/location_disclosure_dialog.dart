/// In-app location prominent-disclosure dialog.
///
/// Satisfies Google Play's "Prominent Disclosure & Consent" requirement: an
/// affirmative, in-app disclosure of WHY/WHAT/HOW location is used, shown
/// BEFORE the OS runtime permission prompt. It does not itself request any
/// permission; it only records the user's informed consent.
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

  /// HOW the data is protected, and every third party it reaches.
  ///
  /// An earlier version ended "never Haven, and never any other entity."
  /// That was false, and false inside the artefact that records consent:
  /// encrypted location transits third-party relays (three public operators
  /// by default) that also see the user's network address, and drawing the
  /// map sends tile coordinates derived from circle members' positions to an
  /// outside map provider. A Prominent Disclosure has to name third-party
  /// transmission, not deny it. Do not reintroduce an absolute here.
  ///
  /// The Stadia Maps sentence is attributed to their published policy on
  /// purpose, and states the log-retention window. Verified 2026-07-29 at
  /// [kStadiaPrivacyUrl]: they do not sell/rent/trade personal information,
  /// set no cookies for end users of apps built on their services, and keep
  /// server logs ~7-14 days. Their IP-anonymisation commitment covers their
  /// ANALYTICS system, NOT API request logs, so this must never be shortened
  /// to a 'no logging' or 'anonymous' claim, which would be false.
  static const String how =
      'Your location is end-to-end encrypted on your device, so only the '
      'members of the circles you choose can read it, not Haven. Haven runs '
      'no servers of its own: your encrypted updates pass through independent '
      'relays run by other people, which see your network address but never '
      'where you are. Drawing the map asks Stadia Maps for the areas around '
      'you and your circle, so it learns roughly where that is, but never '
      'your name, your key, or who is in your circles. Under its published '
      'privacy policy Stadia Maps does not sell or trade personal '
      'information and sets no cookies on your device, and it keeps server '
      'logs for about two weeks.';

  /// WHEN sharing happens, and the only way to stop it.
  ///
  /// Always shown, unlike [background] and [manage], which render only in the
  /// background scope. Foreground sharing is unconditional and there is no
  /// pause, so a dialog that offered only the background toggle as "control"
  /// would advertise a switch while withholding the main behaviour.
  static const String sharing =
      'While Haven is open and you are in a circle, your location is sent '
      'automatically every couple of minutes. There is no pause. To stop '
      'sharing with a circle, leave it.';

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
              const SizedBox(height: HavenSpacing.base),
              Text(
                LocationDisclosureStrings.sharing,
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
