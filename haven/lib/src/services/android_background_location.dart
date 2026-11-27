/// Android's "Allow all the time" location permission, over Haven's own
/// `haven.app/background_location` channel (`BackgroundLocation.kt`).
///
/// Android 11+ lets a foreground service started at boot, after an update or
/// by a system restart use location only with `ACCESS_BACKGROUND_LOCATION`;
/// without it Haven can share only while it was started from the visible app.
/// The channel requests that permission alone — the documented shape — and
/// reports the OS's own localized label for the option, which the disclosure
/// quotes verbatim.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/background_location_provider.dart';

/// What the platform reports about the background location permission.
@immutable
class BackgroundLocationStatus {
  /// Creates a status reading.
  const BackgroundLocationStatus({
    required this.required,
    required this.granted,
    this.optionLabel,
    this.foregroundGranted = true,
  });

  /// Off Android, and on Android 10 and below: nothing to ask for.
  static const BackgroundLocationStatus notRequired = BackgroundLocationStatus(
    required: false,
    granted: true,
  );

  /// An unreadable channel. Over-warns rather than telling a user who cannot
  /// be restarted after a reboot that they can.
  static const BackgroundLocationStatus failClosed = BackgroundLocationStatus(
    required: true,
    granted: false,
    foregroundGranted: false,
  );

  /// Whether this Android version needs the permission (API 30+).
  final bool required;

  /// Whether it is held; `true` whenever it is not [required].
  final bool granted;

  /// The OS's own localized "Allow all the time" label, when it has one.
  final String? optionLabel;

  /// Whether a foreground location grant is held. Android shows its
  /// background page only on top of one; without it a request falls through
  /// to the App info page.
  final bool foregroundGranted;

  /// Whether Haven still has to ask.
  bool get missing => required && !granted;
}

/// The background location permission, as Haven asks for it.
abstract class AndroidBackgroundLocation {
  /// Reads the permission state.
  Future<BackgroundLocationStatus> status();

  /// Requests the permission and completes when the OS answers. Returns
  /// whether the OS showed anything: after repeated denials Android answers at
  /// once without its page, and only app settings can then grant it.
  Future<bool> request();

  /// Opens Haven's app-details page in system settings.
  Future<void> openAppSettings();
}

/// The channel-backed implementation (Android).
class MethodChannelAndroidBackgroundLocation
    implements AndroidBackgroundLocation {
  /// Creates the channel client. [channel] is a test seam.
  const MethodChannelAndroidBackgroundLocation({
    MethodChannel channel = const MethodChannel(channelName),
  }) : _channel = channel;

  /// The channel name the Kotlin side registers.
  static const String channelName = 'haven.app/background_location';

  final MethodChannel _channel;

  @override
  Future<BackgroundLocationStatus> status() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      if (raw == null) return BackgroundLocationStatus.failClosed;
      final required = raw['required'];
      final granted = raw['granted'];
      final label = raw['optionLabel'];
      if (required is! bool || granted is! bool) {
        return BackgroundLocationStatus.failClosed;
      }
      return BackgroundLocationStatus(
        required: required,
        granted: granted || !required,
        optionLabel: label is String && label.isNotEmpty ? label : null,
        foregroundGranted: raw['foregroundGranted'] == true,
      );
    } on PlatformException catch (e) {
      debugPrint('[BackgroundLocation] status failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[BackgroundLocation] status: no native handler');
    }
    return BackgroundLocationStatus.failClosed;
  }

  @override
  Future<bool> request() async {
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } on PlatformException catch (e) {
      debugPrint('[BackgroundLocation] request failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[BackgroundLocation] request: no native handler');
    }
    return false;
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } on PlatformException catch (e) {
      debugPrint('[BackgroundLocation] openAppSettings failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[BackgroundLocation] openAppSettings: no native handler');
    }
  }
}

/// Off Android: there is no such permission, so nothing is ever missing.
class NotRequiredBackgroundLocation implements AndroidBackgroundLocation {
  /// Creates the no-op implementation.
  const NotRequiredBackgroundLocation();

  @override
  Future<BackgroundLocationStatus> status() async =>
      BackgroundLocationStatus.notRequired;

  @override
  Future<bool> request() async => false;

  @override
  Future<void> openAppSettings() async {}
}

/// Requests the permission and returns what holds afterwards, re-read rather
/// than trusted from the request. When the OS showed nothing and the
/// permission is still missing, its page will not appear again, so Haven's
/// app-details page is opened instead (the only remaining way to grant it).
Future<BackgroundLocationStatus> requestBackgroundLocation(
  AndroidBackgroundLocation api,
) async {
  final shown = await api.request();
  final after = await api.status();
  if (after.missing && !shown) await api.openAppSettings();
  return after;
}

/// The platform's background-location permission client.
final androidBackgroundLocationProvider = Provider<AndroidBackgroundLocation>(
  (ref) => ref.watch(platformIsAndroidProvider)
      ? const MethodChannelAndroidBackgroundLocation()
      : const NotRequiredBackgroundLocation(),
);

/// The current background-location permission reading. Invalidated on every
/// return to the foreground by the screens that show it: a grant made in
/// system settings does not restart the process.
final backgroundLocationStatusProvider =
    FutureProvider<BackgroundLocationStatus>(
      (ref) => ref.watch(androidBackgroundLocationProvider).status(),
    );
