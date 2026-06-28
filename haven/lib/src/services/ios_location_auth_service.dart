/// iOS-only bridge for the CoreLocation "Always" authorization.
///
/// Continuous background location delivery — which Haven's background-sharing
/// feature depends on — requires the iOS "Always" authorization. The
/// `geolocator` plugin can only ever request "When In Use" on iOS: its native
/// handler calls `requestWhenInUseAuthorization` whenever
/// `NSLocationWhenInUseUsageDescription` is present and short-circuits once a
/// status is set, so `requestAlwaysAuthorization` is never reached. Haven
/// therefore talks to a small native handler (`HavenLocationAuthHandler`)
/// over a [MethodChannel] to call `requestAlwaysAuthorization()` directly.
///
/// On every non-iOS platform the implementation is a no-op that reports
/// [IosAuthStatus.always], so platform-agnostic callers never have to branch on
/// the platform (Android background uses a foreground service, not this
/// authorization).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The CoreLocation authorization status, mirrored from
/// `CLAuthorizationStatus`.
enum IosAuthStatus {
  /// The user has not yet chosen whether the app can use location.
  notDetermined,

  /// The app is not authorized and the user cannot change it (e.g. parental
  /// controls / MDM restriction).
  restricted,

  /// The user denied location access for the app.
  denied,

  /// The app is authorized to use location only while in use (foreground).
  whenInUse,

  /// The app is authorized to use location at any time, including background.
  always,

  /// The native status could not be determined (unexpected channel reply or no
  /// native handler). Treated as "not Always" by callers.
  unknown,
}

/// Bridge for the iOS CoreLocation "Always" authorization.
abstract class IosLocationAuthService {
  /// Returns the current authorization status without prompting the user.
  Future<IosAuthStatus> checkStatus();

  /// Requests "Always" authorization and resolves to the resulting status.
  ///
  /// On iOS this asks CoreLocation for `requestAlwaysAuthorization()`. The OS
  /// only presents a prompt when the app currently holds
  /// [IosAuthStatus.whenInUse] or [IosAuthStatus.notDetermined]; otherwise the
  /// current status is returned unchanged. The returned future always resolves
  /// — a native timeout guard prevents it from hanging if the OS never invokes
  /// the authorization delegate.
  Future<IosAuthStatus> requestAlways();
}

/// Returns the platform-appropriate [IosLocationAuthService].
///
/// iOS receives the [MethodChannel]-backed implementation; every other platform
/// receives a no-op that always reports [IosAuthStatus.always].
IosLocationAuthService createIosLocationAuthService() {
  return Platform.isIOS
      ? const MethodChannelIosLocationAuthService()
      : const NoopIosLocationAuthService();
}

/// [MethodChannel]-backed [IosLocationAuthService] talking to the native
/// `HavenLocationAuthHandler`.
class MethodChannelIosLocationAuthService implements IosLocationAuthService {
  /// Creates a [MethodChannelIosLocationAuthService].
  const MethodChannelIosLocationAuthService();

  /// The platform channel shared with the native handler.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'haven.app/ios_location_auth',
  );

  @override
  Future<IosAuthStatus> checkStatus() => _invoke('checkAlwaysStatus');

  @override
  Future<IosAuthStatus> requestAlways() =>
      _invoke('requestAlwaysAuthorization');

  Future<IosAuthStatus> _invoke(String method) async {
    try {
      final result = await channel.invokeMethod<String>(method);
      return statusFromString(result);
    } on PlatformException catch (e) {
      // No key material involved; logging the opaque error code is safe.
      debugPrint('[IosLocationAuth] $method failed: ${e.code}');
      return IosAuthStatus.unknown;
    } on MissingPluginException {
      debugPrint('[IosLocationAuth] $method: no native handler registered');
      return IosAuthStatus.unknown;
    }
  }

  /// Maps a native status string to an [IosAuthStatus].
  ///
  /// Any unrecognised or null value maps to [IosAuthStatus.unknown].
  @visibleForTesting
  static IosAuthStatus statusFromString(String? raw) {
    switch (raw) {
      case 'notDetermined':
        return IosAuthStatus.notDetermined;
      case 'restricted':
        return IosAuthStatus.restricted;
      case 'denied':
        return IosAuthStatus.denied;
      case 'whenInUse':
        return IosAuthStatus.whenInUse;
      case 'always':
        return IosAuthStatus.always;
      case _:
        return IosAuthStatus.unknown;
    }
  }
}

/// No-op [IosLocationAuthService] for non-iOS platforms.
///
/// Always reports [IosAuthStatus.always] so platform-agnostic callers can treat
/// "has Always" as the non-iOS default — there is no CoreLocation authorization
/// to limit background sharing off iOS.
class NoopIosLocationAuthService implements IosLocationAuthService {
  /// Creates a [NoopIosLocationAuthService].
  const NoopIosLocationAuthService();

  @override
  Future<IosAuthStatus> checkStatus() async => IosAuthStatus.always;

  @override
  Future<IosAuthStatus> requestAlways() async => IosAuthStatus.always;
}
