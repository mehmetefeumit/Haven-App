/// Opens the OS screens that restore lost location access.
///
/// Losing location access has two different remedies and the user cannot be
/// expected to know which one applies: turning the DEVICE-WIDE location
/// provider back on lives in the system location settings, while re-granting
/// Haven's own location permission lives in the app's settings page. This
/// abstraction lets the map surface hand the user straight to the right one
/// (see `LocationAccessStatus`), and lets tests assert which one was chosen
/// without touching a platform channel.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart' as geo;

/// Opens the OS settings screens relevant to location access.
abstract class LocationSettingsLauncher {
  /// Opens the device-wide location settings (the "Location" master toggle).
  ///
  /// Returns `true` when the OS accepted the request. Never throws.
  Future<bool> openLocationSettings();

  /// Opens Haven's own application settings page, where the location
  /// permission can be re-granted after a denial.
  ///
  /// Returns `true` when the OS accepted the request. Never throws.
  Future<bool> openAppSettings();
}

/// Production [LocationSettingsLauncher] backed by geolocator's OS intents.
class GeolocatorSettingsLauncher implements LocationSettingsLauncher {
  /// Creates the production launcher.
  const GeolocatorSettingsLauncher();

  @override
  Future<bool> openLocationSettings() async {
    try {
      return await geo.Geolocator.openLocationSettings();
    } on Object catch (e) {
      // Never surface the raw error (Security Rule 8) and never throw out of a
      // button handler: a settings intent the OS refuses is a dead end, not a
      // crash.
      debugPrint('[LocationSettings] open location settings: ${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<bool> openAppSettings() async {
    try {
      return await geo.Geolocator.openAppSettings();
    } on Object catch (e) {
      debugPrint('[LocationSettings] open app settings: ${e.runtimeType}');
      return false;
    }
  }
}
