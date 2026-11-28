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
/// left through a dispatched `resumed` — or, in an iOS process no scene has
/// connected to, never: only a view controller in a window sends lifecycle
/// messages.
bool pausedAtMount(AppLifecycleState? lifecycle) =>
    lifecycle == AppLifecycleState.paused;

/// What the first pause of a process owes a location relaunch.
enum LaunchSession {
  /// Not a location relaunch: the ordinary pause.
  none,

  /// A location relaunch the current background disclosure does not cover:
  /// no session is started and nothing is published from it.
  receiveOnly,

  /// A location relaunch under the current disclosure with sharing on: start
  /// the background session, then burst.
  resume,
}

/// The mount and the start-up of a shell, behind hooks the shell supplies.
///
/// A shell mounted under `paused` stamps no foreground and takes the pause it
/// missed, once what the pause handler reads has loaded — unless a lifecycle
/// change has reached it first. Its start-up contacts no relay unless the app
/// reads `resumed` then, and again after each await of the contact: the
/// contact is owed to the next resume, which pays it once.
///
/// A process iOS started in the background that takes a location event
/// before any scene comes to the front (a location launch, D4) takes a pause
/// even when it mounted under `inactive` or `detached`, where none may ever
/// be dispatched, and that pause — whichever path delivers it, and
/// whether it lands before or after the launch's reads resolve — is handed
/// the [LaunchSession] once ([takeLaunchSession]). The native side marks
/// such a process at its first location delivery, which can follow the
/// mount's read: until a lifecycle change reaches the shell, each
/// [locationLaunches] report reads the launch again. The foreground consent
/// step is shown only while the app reads `resumed`, owed to the first
/// resume.
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

  /// Whether this process is a location launch (the native session's read).
  @protected
  Future<bool> launchedForLocation();

  /// Fires when the native side has just marked this process launched for
  /// location.
  @protected
  Stream<void> get locationLaunches;

  /// In a location relaunch only: reads what the launch's first pause needs —
  /// the sharing consent, the current-disclosure predicate and the roster,
  /// bounded — and answers whether that pause may start sharing.
  @protected
  Future<bool> launchMayResume();

  /// The foreground consent step. Answers false when the app left the front
  /// before anything was shown, which owes it to the next resume.
  @protected
  Future<bool> foregroundConsentStep();

  bool _relayContactOwed = false;
  bool _consentStepOwed = false;

  /// The launch's reads, from the mount; completes with what is owed.
  Completer<LaunchSession> _launch = Completer<LaunchSession>();

  /// What [_launch] completed with, once it has.
  LaunchSession? _launchRead;

  /// Whether the [LaunchSession] has been handed to a pause.
  bool _launchTaken = false;

  /// Whether a pause is in effect: from an admitted pause to the next resume.
  bool _pauseInEffect = false;

  /// Whether any resume has been dispatched to this shell.
  bool _resumeSeen = false;

  /// Whether the pause in effect is one this gate took while the binding
  /// still read the `detached` seed.
  bool _pausedOverSeed = false;

  StreamSubscription<void>? _launchReports;

  /// `paused` while a pause this gate took over the never-replaced `detached`
  /// seed is in effect, else what the binding reads: no lifecycle message
  /// reaches an iOS process no scene has connected to, and a burst that read
  /// the seed there would want no session.
  @protected
  AppLifecycleState? get effectiveLifecycle =>
      _pausedOverSeed &&
          _pauseInEffect &&
          currentLifecycle == AppLifecycleState.detached
      ? AppLifecycleState.paused
      : currentLifecycle;

  /// From `initState`.
  void gateMount() {
    final paused = pausedAtMount(currentLifecycle);
    if (!paused) stampForeground();
    _launchReports = locationLaunches.listen((_) => unawaited(_relaunch()));
    unawaited(_resolveMount(pausedAtMount: paused));
  }

  @override
  void dispose() {
    unawaited(_launchReports?.cancel());
    super.dispose();
  }

  void _takeGatePause() {
    _pausedOverSeed = currentLifecycle == AppLifecycleState.detached;
    takePause();
  }

  // Never inside the build that mounts the shell: the pause writes provider
  // state, and the waits below yield first even when everything has loaded.
  Future<void> _resolveMount({required bool pausedAtMount}) async {
    final launch = await _readLaunch();
    _launchRead = launch;
    _launch.complete(launch);
    if (pausedAtMount) {
      try {
        await beforeMissedPause();
      } on Object catch (_) {
        // A consent that could not be read is read as off by the pause.
      }
    }
    if (!mounted) return;
    // Only a launch that may resume takes a pause of its own: one the
    // current disclosure does not cover stays as it was (R-2).
    if (lifecycleTurn == 0) {
      if (pausedAtMount || launch == LaunchSession.resume) _takeGatePause();
      return;
    }
    // A dispatched change reached the shell first. A pause has been handed the
    // launch; a resume owns the shell — unless it was the one the binding
    // synthesizes when a scene connecting to a background launch sends its
    // first message over the `detached` seed (detached → resumed → inactive).
    // The native flag tells the two apart: the scene's first foreground
    // clears it.
    if (launch != LaunchSession.resume || !_awayWithLaunchOwed()) return;
    if (await _stillLaunched(launch) == LaunchSession.none) return;
    if (mounted && _awayWithLaunchOwed()) _takeGatePause();
  }

  // Only a launch read as none is read again, and only before any lifecycle
  // change reached the shell: after one, a pause or a resume owns what is
  // owed.
  bool _relaunchOpen() =>
      mounted &&
      lifecycleTurn == 0 &&
      !_launchTaken &&
      _launchRead == LaunchSession.none;

  // What the mount would have done had the flag been set when it read it.
  Future<void> _relaunch() async {
    await _launch.future;
    if (!_relaunchOpen()) return;
    final launch = await _readLaunch();
    if (launch == LaunchSession.none || !_relaunchOpen()) return;
    _launchRead = launch;
    _launch = Completer<LaunchSession>()..complete(launch);
    if (launch == LaunchSession.resume) _takeGatePause();
  }

  bool _awayWithLaunchOwed() =>
      !_launchTaken &&
      !_pauseInEffect &&
      currentLifecycle != AppLifecycleState.resumed;

  Future<LaunchSession> _stillLaunched(LaunchSession launch) async {
    if (launch == LaunchSession.none) return launch;
    try {
      return await launchedForLocation() ? launch : LaunchSession.none;
    } on Object catch (_) {
      return LaunchSession.none;
    }
  }

  Future<LaunchSession> _readLaunch() async {
    try {
      if (!await launchedForLocation()) return LaunchSession.none;
    } on Object catch (_) {
      // Unreadable is not launched: no relaunch routing at all.
      return LaunchSession.none;
    }
    try {
      return await launchMayResume()
          ? LaunchSession.resume
          : LaunchSession.receiveOnly;
    } on Object catch (_) {
      return LaunchSession.receiveOnly;
    }
  }

  /// From the pause handler's iOS sharing-on branch: what this pause owes a
  /// location relaunch, or null when it owes nothing (not a relaunch, or
  /// already handed to an earlier pause). Pending while the launch's reads
  /// are, so a pause dispatched before they resolve is handed the outcome
  /// rather than missing it.
  ///
  /// After a resume the native flag is read again: a user who opened the app
  /// cleared it, and their later pause is an ordinary one.
  Future<LaunchSession>? takeLaunchSession() {
    if (_launchTaken) return null;
    _launchTaken = true;
    if (_launchRead == LaunchSession.none) return null;
    return _resumeSeen ? _launch.future.then(_stillLaunched) : _launch.future;
  }

  /// From the pause handler, first: whether this pause runs at all. A pause
  /// taken for a background launch leaves the binding at `inactive`, so iOS
  /// can dispatch a `paused` on top of it; a second run would cancel the
  /// first pause's burst mid-flight. The binding itself never dispatches
  /// paused twice in a row, so nothing else is skipped.
  bool admitPause() {
    if (_pauseInEffect) return false;
    _pauseInEffect = true;
    return true;
  }

  /// From the resume handler, first.
  void noteResume() {
    _pauseInEffect = false;
    _pausedOverSeed = false;
    _resumeSeen = true;
  }

  /// From the start-up.
  Future<void> gateStartUp() async {
    if (currentLifecycle == AppLifecycleState.resumed) {
      await startUpRelayContact();
    } else {
      _relayContactOwed = true;
    }
  }

  /// From the start-up: the consent step now if the app reads `resumed`, else
  /// owed to the first resume. Never from a background launch.
  Future<void> gateConsentStep() async {
    if (currentLifecycle != AppLifecycleState.resumed) {
      _consentStepOwed = true;
      return;
    }
    if (!await foregroundConsentStep()) _consentStepOwed = true;
  }

  /// From the resume handler, on every resume.
  Future<void> payOwedConsentStep() async {
    if (!_consentStepOwed) return;
    _consentStepOwed = false;
    if (!await foregroundConsentStep()) _consentStepOwed = true;
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
