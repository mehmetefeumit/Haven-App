/// The foreground-service entry point the Android resume lane
/// (`e2e-android-resume.yml`) starts the service with.
///
/// The lane resumes sharing in a NEW process — after an update, a reboot and a
/// kill — and asserts that it publishes. The debug-only `ws://` loopback
/// opt-in (`allowWsLoopbackForTest`) has no on-disk form, so that process
/// would refuse the hermetic `ws://10.0.2.2:7777` relay before opening a
/// socket. This entry point is `backgroundCallback`'s handler with ONE delta:
/// the opt-in, installed through the handler's own post-bridge hook (the
/// bridge cannot be initialised twice). The system-start gate, the bring-up
/// and the publish cycle run unmodified. The plugin stores this function's
/// handle, so every start the lane makes — the UI one, the update one, the
/// boot one, the sticky one — runs it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:haven/src/rust/api.dart' show allowWsLoopbackForTest;
import 'package:haven/src/services/background_location_task.dart';

/// Logged once the opt-in is installed in the service's process.
const String kResumeCiLoopbackArmedMarker =
    '[ResumeCI] ws:// loopback opt-in armed';

/// The CI twin of `backgroundCallback`.
@pragma('vm:entry-point')
void resumeCiBackgroundCallback() {
  FlutterForegroundTask.setTaskHandler(
    BackgroundLocationTaskHandler()..afterBridgeInitForTest = _armWsLoopback,
  );
}

void _armWsLoopback() {
  try {
    allowWsLoopbackForTest();
    debugPrint(kResumeCiLoopbackArmedMarker);
  } on Object catch (e) {
    debugPrint('[ResumeCI] ws:// loopback opt-in failed: ${e.runtimeType}');
  }
}
