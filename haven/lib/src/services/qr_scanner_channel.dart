/// The Dart end of Haven's native QR scanner.
///
/// The camera and the decoder are native (`QrScanner.kt`: CameraX + zxing-cpp;
/// `HavenQrScannerHandler.swift`: AVFoundation + Vision). Only decoded text
/// crosses the channel; frames never do.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the scanner may use a camera.
enum QrCameraAccess {
  /// Permission granted and a camera exists.
  granted,

  /// Permission not granted; the OS may or may not still prompt.
  denied,

  /// The device has no camera Haven can use.
  unavailable,
}

/// Talks to the native scanner over `haven.app/qr_scanner`.
class QrScannerChannel {
  /// Creates the channel; tests pass their own [channel].
  QrScannerChannel({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(name);

  /// The method channel name both platforms register.
  static const String name = 'haven.app/qr_scanner';

  /// The platform view type both platforms register.
  static const String viewType = 'haven.app/qr_scanner_view';

  final MethodChannel _channel;

  /// Camera access, asking the user if the OS still may.
  Future<QrCameraAccess> requestAccess() => _access('requestAccess');

  /// Camera access, never prompting.
  Future<QrCameraAccess> checkAccess() => _access('checkAccess');

  Future<QrCameraAccess> _access(String method) async {
    try {
      return switch (await _channel.invokeMethod<String>(method)) {
        'granted' => QrCameraAccess.granted,
        'denied' => QrCameraAccess.denied,
        _ => QrCameraAccess.unavailable,
      };
    } on Object catch (e) {
      debugPrint('[QrScanner] $method: ${e.runtimeType}');
      return QrCameraAccess.unavailable;
    }
  }

  /// Turns the torch on or off; a camera without one ignores it.
  Future<void> setTorch({required bool on}) => _call('setTorch', on);

  /// Switches between the rear and front camera, when both exist.
  Future<void> switchCamera() => _call('switchCamera');

  /// Releases the camera now rather than when the platform view is collected.
  Future<void> stop() => _call('stop');

  Future<void> _call(String method, [Object? argument]) async {
    try {
      await _channel.invokeMethod<void>(method, argument);
    } on Object catch (e) {
      debugPrint('[QrScanner] $method: ${e.runtimeType}');
    }
  }

  /// Receives the scanner's events until [stopListening].
  void listen({
    required ValueChanged<String> onDetected,
    required ValueChanged<bool> onTorch,
    required VoidCallback onUnavailable,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'detected':
          final text = call.arguments;
          if (text is String) onDetected(text);
        case 'torch':
          onTorch(call.arguments == true);
        case 'unavailable':
          onUnavailable();
      }
    });
  }

  /// Stops delivering events.
  void stopListening() => _channel.setMethodCallHandler(null);
}
