/// The one way an E2E target records that the user accepted Haven's location
/// disclosures.
///
/// A seed of the background bool alone reads as an acceptance of version 1:
/// MapShell's first foreground then re-shows the updated disclosure over
/// whatever the target meant to drive, and sharing that starts again without
/// the user opening Haven stays withheld. The version is a parameter so a lane
/// can seed an older acceptance on purpose.
///
/// The Android "Allow all the time" step is recorded as shown too: a seeded
/// user has been through the disclosure that carries it, and without the
/// record MapShell's consent step puts a modal over the map of every Android
/// 11+ lane that does not grant ACCESS_BACKGROUND_LOCATION.
library;

import 'package:haven/src/constants/location.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records both disclosures as accepted at [version], that version as shown
/// and the all-time step as shown, in the order the app writes them (the
/// version last).
Future<void> seedLocationDisclosuresAccepted(
  SharedPreferences prefs, {
  int version = kBackgroundDisclosureVersion,
}) async {
  await prefs.setBool(kAndroidBackgroundLocationPromptedKey, true);
  await prefs.setBool(kLocationDisclosureAcceptedKey, true);
  await prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, true);
  await prefs.setInt(kLocationDisclosureBackgroundPromptedVersionKey, version);
  await prefs.setInt(kLocationDisclosureBackgroundVersionKey, version);
}

/// Removes every key [seedLocationDisclosuresAccepted] writes.
Future<void> clearLocationDisclosures(SharedPreferences prefs) async {
  await prefs.remove(kLocationDisclosureAcceptedKey);
  await prefs.remove(kLocationDisclosureBackgroundAcceptedKey);
  await prefs.remove(kLocationDisclosureBackgroundPromptedVersionKey);
  await prefs.remove(kLocationDisclosureBackgroundVersionKey);
  await prefs.remove(kAndroidBackgroundLocationPromptedKey);
}
