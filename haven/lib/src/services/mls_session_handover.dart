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
import 'package:flutter/widgets.dart';


/// Ceiling on how long the foreground service's `onDestroy` WAITS for the
/// location publish that was in flight when the stop arrived.
///
/// Lives here, beside [handoverTimeout], because the two are one number seen
/// from both ends: `background_location_task.dart` enforces it on the drain,
/// and this file must not give up before it could even have elapsed. Split
/// across two files they drift. `scripts/ci/check_teardown_drain_budget.sh`
/// pins the arithmetic below against the Rust constants it is derived from.
///
/// Sized to ONE relay publish attempt — `CONNECTION_TIMEOUT` (5 s) +
/// `DEFAULT_TIMEOUT` (10 s) in `haven-core/src/relay/manager.rs` — not that
/// module's full three-attempt ~49 s ladder. The retries exist to buy back a
/// location sample, and a service that is stopping will not publish another.
/// Rule 13 is not at stake for the step this bounds: a location is an MLS
/// *application* message, so abandoning one costs a sample, never a commit.
/// (The commit-critical half of a cycle is drained separately and UNBOUNDED —
/// see `background_location_task.dart`.)
///
/// # What it does NOT bound
///
/// It bounds the WAIT, not the release. An abandoned publish keeps running in
/// Rust, and its future still owns an `Arc<CoreCircleManager>` until the whole
/// ladder finishes — so the Rule-14 guard can legitimately stay held for tens
/// of seconds after `onDestroy` returns. Nothing here can shorten that; only
/// the ladder finishing does.
const Duration kBackgroundTeardownDrainBudget = Duration(
  seconds: _teardownDrainBudgetSecs,
);

const int _teardownDrainBudgetSecs = 15;

/// What the service spends after the drain: the bounded relay shutdown and the
/// `dispose()` that actually frees this isolate's own handle, plus the stop
/// request's own trip across the platform channel.
const int _teardownAfterDrainSecs = 5;

/// How long to wait for the service to release the guard before giving up.
///
/// Derived, not chosen: give up sooner than the service's own teardown bound
/// and this abandons a service that was going to comply, wastes the caller's
/// one retry, and leaves the user on a blank map anyway. Summed in seconds
/// rather than as `Duration`s because a default parameter value has to be
/// `const`, and `Duration.+` is not.
///
/// # This is a floor on patience, not a promise
///
/// Waiting it out does NOT mean the guard must be free afterwards. A publish
/// the service abandoned at [kBackgroundTeardownDrainBudget] keeps its
/// `Arc<CoreCircleManager>` until its relay ladder ends (~49 s worst case), so
/// a `timedOut` here can perfectly well mean "still shutting down" rather than
/// "wedged". That is why `timedOut` is not treated as a dead end:
/// `NostrCircleService._recoverHeldSession` follows it with a registry re-read,
/// a force-release and ONE retry, which absorbs both readings without this
/// number having to be big enough to cover the worst one.
///
/// The common case does not pay for any of it — an idle service destroys in
/// milliseconds and the poll below exits as soon as the guard clears.
const Duration handoverTimeout = Duration(
  seconds: _teardownDrainBudgetSecs + _teardownAfterDrainSecs,
);

/// Gap between guard re-checks while waiting for the service to let go.
const Duration handoverPollInterval = Duration(milliseconds: 250);

/// Whether the app is currently foregrounded.
///
/// The main isolate stays alive while background location sharing runs, and
/// `MapShell` is not disposed when the app is backgrounded, so neither widget
/// lifetime nor "this code is running" is a foreground proxy.
///
/// A null `lifecycleState` — before the first lifecycle event, i.e. startup,
/// and in unit tests — counts as foregrounded.
bool appIsForegrounded() {
  try {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  } on Object {
    // No binding (pure-Dart test context) — nothing to defer to.
    return true;
  }
}

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

  /// The app is backgrounded, so this open was not the user waiting on a blank
  /// screen — it was routine background maintenance. Stopping the service for
  /// it would kill background location sharing to satisfy a task that can
  /// simply wait.
  backgrounded,
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
  bool Function() isForegrounded = appIsForegrounded,
  Duration timeout = handoverTimeout,
  Duration pollInterval = handoverPollInterval,
  Future<void> Function(Duration) delay = _defaultDelay,
}) async {
  // Only recover for the FOREGROUND. This exists because a user opening the
  // app finds no circles, no map and no location — a total, visible failure
  // worth stopping the service over. But `initialize()` is ALSO reached from
  // background maintenance (the KeyPackage and relay-list ticks keep running
  // while paused, unlike every MapShell timer), and there the trade inverts:
  // stopping the service would kill background location sharing to satisfy a
  // routine task that can wait for the next foreground. Ungated, a KeyPackage
  // tick ~30 minutes into any backgrounded session would take the session back
  // from the service and silently end background publishing.
  if (!isForegrounded()) return HandoverOutcome.backgrounded;

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
