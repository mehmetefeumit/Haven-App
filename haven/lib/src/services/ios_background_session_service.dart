/// iOS-only bridge for the CoreLocation background session objects.
///
/// The legacy `CLLocationManager.allowsBackgroundLocationUpdates` contract
/// that the unified position stream relies on is no longer sufficient on its
/// own for reliable background delivery on modern iOS. Since iOS 17 Apple's
/// supported way for a When-In-Use app to keep receiving location updates in
/// the background is to hold a `CLBackgroundActivitySession`, and since
/// iOS 18 "Always" authorization is only effective while the app holds a
/// `CLServiceSession`. The `geolocator` plugin has adopted neither, so Haven
/// talks to a small native handler (`HavenBackgroundSessionHandler`) over a
/// [MethodChannel] that holds both session objects while background sharing
/// is enabled.
///
/// The native `arm` re-reads the persisted background-sharing consent at call
/// time and no-ops when it is off, so a racing disable can never leave a
/// session held against the user's intent. On every non-iOS platform the
/// implementation is a no-op (Android background uses a foreground service,
/// not CoreLocation sessions).
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Which CoreLocation session objects the native handler currently holds.
///
/// Surfaced for integration tests: asserting [backgroundActivitySessionHeld]
/// after enabling background sharing is the runtime proof that the native
/// keep-alive contract is armed.
@immutable
class IosBackgroundSessionStatus {
  /// Creates an [IosBackgroundSessionStatus].
  const IosBackgroundSessionStatus({
    required this.supported,
    required this.backgroundActivitySessionHeld,
    required this.serviceSessionHeld,
  });

  /// Whether the OS supports `CLBackgroundActivitySession` (iOS 17+).
  final bool supported;

  /// Whether a `CLBackgroundActivitySession` is currently held.
  final bool backgroundActivitySessionHeld;

  /// Whether a `CLServiceSession` (iOS 18+, Always-authorized only) is held.
  final bool serviceSessionHeld;
}

/// Bridge for the iOS CoreLocation background session objects.
abstract class IosBackgroundSessionService {
  /// Asks the native handler to hold the background session objects.
  ///
  /// Best-effort and idempotent. The native side re-checks the persisted
  /// background-sharing consent and no-ops when it is off, so callers only
  /// need to sequence this AFTER the consent write.
  Future<void> arm();

  /// Asks the native handler to invalidate and release every held session.
  ///
  /// Idempotent. Must be called on every background-sharing disable so
  /// withdrawal of consent deterministically removes the OS keep-alive.
  Future<void> disarm();

  /// Reports which session objects are currently held.
  Future<IosBackgroundSessionStatus> status();
}

/// Returns the platform-appropriate [IosBackgroundSessionService].
///
/// iOS receives the [MethodChannel]-backed implementation; every other
/// platform receives a no-op.
IosBackgroundSessionService createIosBackgroundSessionService() {
  return Platform.isIOS
      ? const MethodChannelIosBackgroundSessionService()
      : const NoopIosBackgroundSessionService();
}

/// [MethodChannel]-backed [IosBackgroundSessionService] talking to the native
/// `HavenBackgroundSessionHandler`.
class MethodChannelIosBackgroundSessionService
    implements IosBackgroundSessionService {
  /// Creates a [MethodChannelIosBackgroundSessionService].
  const MethodChannelIosBackgroundSessionService();

  /// The platform channel shared with the native handler.
  @visibleForTesting
  static const MethodChannel channel = MethodChannel(
    'haven.app/ios_background_session',
  );

  @override
  Future<void> arm() => _invoke('arm');

  @override
  Future<void> disarm() => _invoke('disarm');

  @override
  Future<IosBackgroundSessionStatus> status() async {
    try {
      final raw = await channel.invokeMapMethod<String, bool>('status');
      return IosBackgroundSessionStatus(
        supported: raw?['supported'] ?? false,
        backgroundActivitySessionHeld:
            raw?['backgroundActivitySessionHeld'] ?? false,
        serviceSessionHeld: raw?['serviceSessionHeld'] ?? false,
      );
    } on PlatformException catch (e) {
      // No key material involved; logging the opaque error code is safe.
      debugPrint('[IosBackgroundSession] status failed: ${e.code}');
    } on MissingPluginException {
      debugPrint('[IosBackgroundSession] status: no native handler registered');
    }
    return const IosBackgroundSessionStatus(
      supported: false,
      backgroundActivitySessionHeld: false,
      serviceSessionHeld: false,
    );
  }

  Future<void> _invoke(String method) async {
    try {
      await channel.invokeMethod<void>(method);
    } on PlatformException catch (e) {
      debugPrint('[IosBackgroundSession] $method failed: ${e.code}');
    } on MissingPluginException {
      debugPrint(
        '[IosBackgroundSession] $method: no native handler registered',
      );
    }
  }
}

/// No-op [IosBackgroundSessionService] for non-iOS platforms.
class NoopIosBackgroundSessionService implements IosBackgroundSessionService {
  /// Creates a [NoopIosBackgroundSessionService].
  const NoopIosBackgroundSessionService();

  @override
  Future<void> arm() async {}

  @override
  Future<void> disarm() async {}

  @override
  Future<IosBackgroundSessionStatus> status() async =>
      const IosBackgroundSessionStatus(
        supported: false,
        backgroundActivitySessionHeld: false,
        serviceSessionHeld: false,
      );
}
