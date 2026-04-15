/// Self-rescheduling one-shot timer that samples a fresh interval per tick.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Fires `onTick` on a cadence where each interval is sampled fresh via
/// `sampleIntervalSecs`.
///
/// Unlike [Timer.periodic], the delay between ticks can vary — which is
/// what enables publish-cadence jitter. Production code wires
/// `sampleIntervalSecs` to the Rust-side CSPRNG via FFI (see
/// `LocationEventService.jitteredPublishIntervalSecs`); tests inject a
/// deterministic sampler.
///
/// Exception semantics:
///   - If `sampleIntervalSecs` throws, the scheduler logs via
///     `debugPrint` and rearms at the nominal duration. This keeps
///     location sharing live under transient FFI errors rather than
///     silently halting.
///   - If `onTick` throws, the exception is caught and the scheduler
///     rearms normally. A failing callback must not kill the periodic
///     loop.
///
/// Cancellation semantics:
///   - [cancel] is idempotent.
///   - [cancel] called from inside `onTick` prevents the subsequent rearm.
///   - After [cancel], [start] may be called again to resume.
class JitteredScheduler {
  /// Creates a scheduler that rearms with a fresh jittered interval on
  /// every tick. The first fire is itself jittered — no immediate fire on
  /// [start].
  JitteredScheduler({
    required Duration nominal,
    required int Function(int nominalSecs) sampleIntervalSecs,
    required VoidCallback onTick,
  }) : _nominal = nominal,
       _sampleIntervalSecs = sampleIntervalSecs,
       _onTick = onTick;

  final Duration _nominal;
  final int Function(int nominalSecs) _sampleIntervalSecs;
  final VoidCallback _onTick;

  Timer? _timer;
  Duration? _lastScheduledDelay;

  /// Last delay the scheduler armed (exposed for debug logging / tests).
  /// Null before [start] and after [cancel].
  Duration? get lastScheduledDelay => _lastScheduledDelay;

  /// Whether a pending tick is armed.
  bool get isActive => _timer != null;

  /// Arms the first tick with a fresh jittered delay. Safe to call after
  /// [cancel] to restart. Calling on an already-active scheduler is a
  /// no-op (prevents accidental double-scheduling).
  void start() {
    if (_timer != null) return;
    _rearm();
  }

  /// Cancels any pending tick. Idempotent — safe to call multiple times
  /// and safe to call from inside `onTick`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _lastScheduledDelay = null;
  }

  void _rearm() {
    int secs;
    try {
      secs = _sampleIntervalSecs(_nominal.inSeconds);
    } on Object catch (e) {
      debugPrint(
        '[JitteredScheduler] sample failed (${e.runtimeType}); '
        'falling back to nominal',
      );
      secs = _nominal.inSeconds;
    }
    final delay = Duration(seconds: secs);
    _lastScheduledDelay = delay;
    _timer = Timer(delay, _fire);
  }

  void _fire() {
    // Clear the current timer handle before invoking onTick so that
    // cancel() called from inside onTick leaves _timer == null and
    // blocks the subsequent rearm.
    _timer = null;
    var cancelled = false;
    try {
      _onTick();
    } on Object catch (e) {
      debugPrint(
        '[JitteredScheduler] onTick threw (${e.runtimeType}); '
        'rearming anyway',
      );
    } finally {
      // If onTick called cancel() synchronously, `_lastScheduledDelay`
      // has been nulled — use that as the cancel signal.
      cancelled = _lastScheduledDelay == null;
      if (!cancelled) {
        _rearm();
      }
    }
  }
}
