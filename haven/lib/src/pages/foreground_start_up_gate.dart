/// What a shell does at its mount and start-up in a process that may not be in
/// front.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Whether a shell mounted under [lifecycle] takes the pause it missed.
///
/// The binding dispatches only changes, so a shell mounted under a binding
/// that already reads `paused` — on Android, an activity stopped during
/// `main()`'s awaits — is dispatched no pause, and nothing would cancel what
/// the mount arms: the foreground stamp and heartbeat, which make a
/// foreground service alive in the process defer to a UI nobody sees. Not
/// `inactive`: a launch dialog is a visible app, and if the app leaves
/// `inactive` for the background a `paused` is dispatched then. Neither the
/// Android nor the iOS embedder sends `hidden`, and the `detached` seed is
/// left through a dispatched `resumed`.
bool pausedAtMount(AppLifecycleState? lifecycle) =>
    lifecycle == AppLifecycleState.paused;

/// The mount and the start-up of a shell, behind hooks the shell supplies.
///
/// A shell mounted under `paused` stamps no foreground and takes the pause it
/// missed, once what the pause handler reads has loaded — unless a lifecycle
/// change has reached it first. Its start-up contacts no relay unless the app
/// reads `resumed` then, and again after each await of the contact: the
/// contact is owed to the next resume, which pays it once.
mixin ForegroundStartUpGate<T extends StatefulWidget> on State<T> {
  /// The lifecycle the binding reads now.
  @protected
  AppLifecycleState? get currentLifecycle =>
      WidgetsBinding.instance.lifecycleState;

  /// How many pauses and resumes have been dispatched to this shell.
  @protected
  int get lifecycleTurn;

  /// Tells the background service the foreground is in front.
  @protected
  void stampForeground();

  /// Completes once what the pause handler reads has been loaded: a pause
  /// that read a consent still loading would take the branch of sharing off.
  @protected
  Future<void> beforeMissedPause();

  /// Runs the pause handler.
  @protected
  void takePause();

  /// The start-up's contact with relays.
  @protected
  Future<void> startUpRelayContact();

  bool _relayContactOwed = false;

  /// From `initState`.
  void gateMount() {
    if (pausedAtMount(currentLifecycle)) {
      unawaited(_takePauseMissedAtMount());
    } else {
      stampForeground();
    }
  }

  // Never inside the build that mounts the shell: the pause writes provider
  // state, and the wait below yields first even when the consent has loaded.
  Future<void> _takePauseMissedAtMount() async {
    try {
      await beforeMissedPause();
    } on Object catch (_) {
      // A consent that could not be read is read as off by the pause.
    }
    if (!mounted || lifecycleTurn != 0) return;
    takePause();
  }

  /// From the start-up.
  Future<void> gateStartUp() async {
    if (currentLifecycle == AppLifecycleState.resumed) {
      await startUpRelayContact();
    } else {
      _relayContactOwed = true;
    }
  }

  /// From [startUpRelayContact], after each await: whether the app still
  /// reads `resumed`. When it does not, the contact is owed again, and the
  /// next resume pays it whole.
  @protected
  bool stillInFront() {
    if (currentLifecycle == AppLifecycleState.resumed) return true;
    _relayContactOwed = true;
    return false;
  }

  /// From the resume handler, on every resume.
  Future<void> payOwedStartUp() async {
    if (!_relayContactOwed) return;
    _relayContactOwed = false;
    await startUpRelayContact();
  }

  /// How close a resume comes to the last one that ran the one-shot extras
  /// for it to skip them: a glance at the notification shade.
  static const Duration resumeDebounce = Duration(seconds: 30);

  static final Stopwatch _monotonic = Stopwatch()..start();

  /// The monotonic clock [resumeExtrasDue] reads.
  @protected
  Duration resumeClock() => _monotonic.elapsed;

  /// When the last resume that ran the extras did, by [resumeClock].
  Duration? _lastResumeExtras;

  /// From the resume handler, after what every resume repairs: whether this
  /// resume runs its one-shot extras. One within [resumeDebounce] of the last
  /// that did skips them, and pays an owed start-up all the same — that is
  /// no extra, it is owed to the first resume whatever its timing. One that
  /// runs them pays it itself, after them.
  bool resumeExtrasDue() {
    final now = resumeClock();
    final last = _lastResumeExtras;
    if (last != null && now - last < resumeDebounce) {
      unawaited(payOwedStartUp());
      return false;
    }
    _lastResumeExtras = now;
    return true;
  }
}
