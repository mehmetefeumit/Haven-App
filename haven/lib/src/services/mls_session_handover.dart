/// Recovery for the UI isolate when the Android foreground service holds the
/// MLS database's single-session guard (Security Rule 14).
///
/// # The failure this exists for
///
/// The service opens its own `CircleManagerFfi` at `onStart`. Normally the UI
/// isolate is already up and wins that race, but on an Android auto-restart of
/// the service — before any Activity exists — the service can take the guard
/// first. Nothing then makes it let go: the UI's own initialisation retries on
/// every call, and every retry hits the same held guard. The user opens the app
/// to no circles, no map, no publishing and no receiving, and it stays that way
/// until they toggle background sharing off or the process dies.
///
/// The service's `onDestroy` DOES release the guard properly (it disposes its
/// manager rather than leaving it to a GC in a dying isolate), so stopping the
/// service is a real fix rather than a hope.
///
/// # Why this direction is not the reclaim in reverse
///
/// The background service's reclaim has to infer that the UI isolate is gone,
/// and is destructive when that inference is wrong — hence its liveness probe
/// and its gates. This direction needs none of that. The UI isolate is by
/// definition present (it is running this code), and stopping the service is
/// something the user's own settings already do routinely. The only judgement
/// is "is the guard actually held", which is read from the process-local
/// registry, never inferred from an error message.
///
/// # Privacy
///
/// Stopping the service pauses background location sharing, so the service is
/// restarted afterwards whenever the user's background-sharing setting is on.
/// Leaving it stopped would silently reduce what the user asked for; the
/// restart keeps the observable behaviour equal to their setting, and the gap
/// is bounded by [handoverTimeout].
library;

import 'dart:async';

import 'package:flutter/foundation.dart';


/// How long to wait for the service to release the guard before giving up.
///
/// Covers the service's `onDestroy`, which awaits an in-flight publish cycle
/// and a relay shutdown before disposing its manager. Too short and the retry
/// fires while the guard is still held, wasting the one attempt; too long and
/// the UI sits on a blank map. This is generous because the wait is only ever
/// entered on a path that is otherwise permanently broken.
const Duration handoverTimeout = Duration(seconds: 12);

/// Gap between guard re-checks while waiting for the service to let go.
const Duration handoverPollInterval = Duration(milliseconds: 250);

/// Why a handover did or did not happen. Returned rather than a bare `bool` so
/// callers and tests can tell "nothing to do" from "tried and failed".
enum HandoverOutcome {
  /// The guard was not held; the open failed for some other reason and
  /// stopping the service would have achieved nothing.
  notHeld,

  /// The service released the guard within the timeout.
  released,

  /// The service was asked to stop but the guard was still held when the
  /// timeout elapsed.
  timedOut,

  /// Stopping the service failed outright.
  stopFailed,
}

/// Asks the foreground service to stop and waits for the MLS guard to clear.
///
/// Every dependency is injected so this is exercisable without the plugin, the
/// Rust bridge, or a real service.
///
/// [isSessionLive] must read the process-local registry. Do NOT pass something
/// that classifies an error string: Haven's FFI errors interpolate
/// remote-authored text (a circle admin controls the group's routing relays),
/// so a remote party could otherwise make this stop the user's background
/// service at will.
///
/// [restartService] is invoked when [backgroundSharingEnabled] is true,
/// regardless of whether the guard was released — the user's setting is not
/// this function's to change.
Future<HandoverOutcome> requestSessionHandover({
  required String dataDir,
  required Future<bool> Function(String dataDir) isSessionLive,
  required Future<void> Function() stopService,
  required Future<void> Function() restartService,
  required bool backgroundSharingEnabled,
  Duration timeout = handoverTimeout,
  Duration pollInterval = handoverPollInterval,
  Future<void> Function(Duration) delay = _defaultDelay,
}) async {
  // Only act on a guard that is genuinely held. A failure with a free guard is
  // something else — a locked keyring, a full disk — that stopping the service
  // cannot fix, and stopping it would cost the user background sharing for
  // nothing.
  if (!await isSessionLive(dataDir)) return HandoverOutcome.notHeld;

  try {
    await stopService();
  } on Object catch (e) {
    debugPrint('[Handover] stop request failed: ${e.runtimeType}');
    return HandoverOutcome.stopFailed;
  }

  var outcome = HandoverOutcome.timedOut;
  var waited = Duration.zero;
  while (waited < timeout) {
    // Poll rather than trust the stop call's completion: the guard is released
    // by the service's `onDestroy` disposing its manager, which runs after the
    // stop request returns and after it drains an in-flight publish.
    await delay(pollInterval);
    waited += pollInterval;
    try {
      if (!await isSessionLive(dataDir)) {
        outcome = HandoverOutcome.released;
        break;
      }
    } on Object catch (e) {
      // A query that cannot answer is not evidence the guard is free.
      debugPrint('[Handover] guard re-check failed: ${e.runtimeType}');
      outcome = HandoverOutcome.timedOut;
      break;
    }
  }

  if (backgroundSharingEnabled) {
    try {
      await restartService();
    } on Object catch (e) {
      // The handover result stands: the UI can now open its session, which is
      // the point. A service that failed to restart is retried by the ordinary
      // background-sharing lifecycle.
      debugPrint('[Handover] restart failed: ${e.runtimeType}');
    }
  }

  return outcome;
}

Future<void> _defaultDelay(Duration d) => Future<void>.delayed(d);
