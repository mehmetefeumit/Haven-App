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

/// One scanner page's end of `haven.app/qr_scanner`.
///
/// The channel is shared, and a page that closes is disposed only after its
/// exit animation, by which time the next page may already be scanning. So
/// every call, every event and the camera view carry this instance's [token],
/// and neither end ever acts on another page's camera or events.
class QrScannerChannel {
  /// Creates one page's end of the channel, with a token of its own.
  QrScannerChannel() : token = _nextToken++;

  /// The method channel name both platforms register.
  static const String name = 'haven.app/qr_scanner';

  /// The platform view type both platforms register.
  static const String viewType = 'haven.app/qr_scanner_view';

  static int _nextToken = 0;
  static final Map<int, void Function(MethodCall)> _listeners = {};

  static const MethodChannel _channel = MethodChannel(name);

  /// Identifies this page's camera view and events to the native side.
  final int token;

  /// What the native view factory is created with.
  Map<String, Object> get creationParams => {'token': token};

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
  Future<void> setTorch({required bool on}) =>
      _call('setTorch', {'token': token, 'on': on});

  /// Switches between the rear and front camera, when both exist.
  Future<void> switchCamera() => _call('switchCamera', {'token': token});

  /// Releases this page's camera now rather than when its view is collected.
  Future<void> stop() => _call('stop', {'token': token});

  Future<void> _call(String method, Map<String, Object> arguments) async {
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object catch (e) {
      debugPrint('[QrScanner] $method: ${e.runtimeType}');
    }
  }

  /// Receives this page's events until [stopListening].
  void listen({
    required ValueChanged<String> onDetected,
    required ValueChanged<bool> onTorch,
    required VoidCallback onUnavailable,
  }) {
    _listeners[token] = (call) {
      final args = call.arguments;
      switch (call.method) {
        case 'detected':
          final text = args is Map ? args['text'] : null;
          if (text is String) onDetected(text);
        case 'torch':
          onTorch(args is Map && args['on'] == true);
        case 'unavailable':
          onUnavailable();
      }
    };
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      final owner = args is Map ? args['token'] : null;
      _listeners[owner]?.call(call);
    });
  }

  /// Stops delivering this page's events; another page's keep flowing.
  void stopListening() {
    _listeners.remove(token);
    if (_listeners.isEmpty) _channel.setMethodCallHandler(null);
  }
}
