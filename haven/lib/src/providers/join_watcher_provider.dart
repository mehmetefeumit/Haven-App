/// Post-circle-add burst-poll watcher.
///
/// Drives a short, jittered burst of fetches against the existing polling
/// pipeline immediately after either:
///   * the admin creates a circle (admin-side window — waiting for the
///     joiner's first wire activity), or
///   * the joiner accepts an invitation (joiner-side window — waiting
///     for the first peer location to land).
///
/// Outside the burst window, the regular 30 s / 60 s / 2 min pollers
/// remain authoritative — this is intentionally narrow scope.
///
/// **Connection privacy** (CLAUDE.md "Metadata & Connection Privacy"):
///   * Window length, per-tick interval, and the open-time delay before
///     the first tick are all sampled per call from `Random.secure()`.
///   * Each tick fires a one-shot fetch via the existing pollers (which
///     issue short REQ–EOSE–CLOSE pairs) — no long-lived subscription.
///   * One burst at a time; starting a new burst cancels any in-flight
///     window so multiple TLS-fingerprint-linked subs do not overlap.
///   * Bursts are triggered exclusively by user-local actions
///     (createCircle / acceptInvitation success), never by a received
///     wire event — no deterministic input→output timing oracle.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/constants/burst.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';

/// Which burst-poll window, if any, is currently active.
enum JoinWatchMode {
  /// No active window — the regular pollers run on their normal cadence.
  idle,

  /// Admin just created a circle and is waiting to see joiners arrive.
  adminWaitingForJoin,

  /// Joiner just accepted and is waiting to see existing members'
  /// locations decrypt.
  joinerWaitingForLocations,
}

/// Snapshot of the watcher's state, exposed for UI.
@immutable
class JoinWatchState {
  /// Default idle state — no burst running.
  const JoinWatchState.idle()
    : mode = JoinWatchMode.idle,
      mlsGroupId = null,
      startedAt = null,
      windowDuration = null;

  /// Active-burst state.
  const JoinWatchState.active({
    required this.mode,
    required this.mlsGroupId,
    required this.startedAt,
    required this.windowDuration,
  });

  /// Current mode; `idle` when no burst is running.
  final JoinWatchMode mode;

  /// MLS group id of the circle whose joins we are watching.
  /// Null while idle.
  final List<int>? mlsGroupId;

  /// When the burst started. Null while idle.
  final DateTime? startedAt;

  /// Total window duration sampled at start. Null while idle.
  final Duration? windowDuration;

  /// True when a burst is in progress.
  bool get isActive => mode != JoinWatchMode.idle;
}

/// Notifier that runs the burst-window state machine.
///
/// All timers are cancelled in [cancel] (also called by [dispose]) so a
/// notifier disposal cannot leak fetch ticks.
class JoinWatcherNotifier extends StateNotifier<JoinWatchState> {
  /// Constructs the notifier wired to a [Ref] so it can invalidate the
  /// existing polling providers on each tick.
  JoinWatcherNotifier(this._ref, {Random? rng})
    : _rng = rng ?? Random.secure(),
      super(const JoinWatchState.idle());

  final Ref _ref;
  final Random _rng;

  Timer? _openDelayTimer;
  Timer? _windowTimer;
  Timer? _tickTimer;

  /// Starts an admin-side burst — the user just created [mlsGroupId].
  ///
  /// Cancels any in-flight burst first.
  void startAdminWatch(List<int> mlsGroupId) {
    _start(
      mode: JoinWatchMode.adminWaitingForJoin,
      mlsGroupId: mlsGroupId,
      params: adminBurst,
    );
  }

  /// Starts a joiner-side burst — the user just accepted into
  /// [mlsGroupId].
  ///
  /// Cancels any in-flight burst first.
  void startJoinerWatch(List<int> mlsGroupId) {
    _start(
      mode: JoinWatchMode.joinerWaitingForLocations,
      mlsGroupId: mlsGroupId,
      params: joinerBurst,
    );
  }

  /// Cancels any in-flight burst and returns to [JoinWatchMode.idle].
  /// Idempotent.
  void cancel() {
    _openDelayTimer?.cancel();
    _openDelayTimer = null;
    _windowTimer?.cancel();
    _windowTimer = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    if (state.isActive) {
      state = const JoinWatchState.idle();
    }
  }

  void _start({
    required JoinWatchMode mode,
    required List<int> mlsGroupId,
    required BurstWindowParams params,
  }) {
    cancel();

    final windowSecs = sampleUniformSecs(
      params.windowMinSecs,
      params.windowMaxSecs,
      _rng,
    );
    final openDelaySecs = sampleUniformSecs(0, params.openDelayMaxSecs, _rng);
    final windowDuration = Duration(seconds: windowSecs);

    state = JoinWatchState.active(
      mode: mode,
      mlsGroupId: mlsGroupId,
      startedAt: DateTime.now(),
      windowDuration: windowDuration,
    );

    debugPrint(
      '[JoinWatcher] starting ${mode.name} '
      'window=${windowSecs}s openDelay=${openDelaySecs}s',
    );

    _openDelayTimer = Timer(Duration(seconds: openDelaySecs), () {
      _openDelayTimer = null;
      _scheduleTick(params);
    });

    _windowTimer = Timer(windowDuration, () {
      _windowTimer = null;
      debugPrint('[JoinWatcher] window expired (${mode.name})');
      cancel();
    });
  }

  void _scheduleTick(BurstWindowParams params) {
    if (!mounted || !state.isActive) return;
    _runTick();
    final delay = sampleUniformSecs(
      params.tickMinSecs,
      params.tickMaxSecs,
      _rng,
    );
    _tickTimer = Timer(Duration(seconds: delay), () {
      _tickTimer = null;
      _scheduleTick(params);
    });
  }

  void _runTick() {
    debugPrint('[JoinWatcher] tick (${state.mode.name})');
    // Each invalidate+read pair triggers the existing polling pipeline,
    // which issues one short REQ–EOSE–CLOSE on existing connections.
    _ref
      ..invalidate(evolutionPollerProvider)
      ..read(evolutionPollerProvider)
      ..invalidate(memberLocationsProvider);
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }
}

/// Singleton join-watcher provider.
///
/// Single instance enforces "one active burst at a time" — a new
/// `startAdminWatch` / `startJoinerWatch` cancels the prior burst.
final joinWatcherProvider =
    StateNotifierProvider<JoinWatcherNotifier, JoinWatchState>(
      JoinWatcherNotifier.new,
    );
