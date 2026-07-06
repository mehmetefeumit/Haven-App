import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/rust/api.dart';

/// Master switch for the persistent live-sync engine (M6).
///
/// While `false` (the default), Haven keeps its established short-poll receive
/// model: the `map_shell` receive/evolution/invitation timers run and the
/// engine is never started. Flipping it to `true` starts the Rust live-sync
/// engine, gates those receive pollers off, and feeds the same providers +
/// persistence from `LiveSyncFfi.liveEvents()` (M6-3).
///
/// Kept as a compile-time `const` (single source of truth) so the gated paths
/// tree-shake out of a release build, mirroring `enablePeriodicSelfUpdate`. The
/// rollout flips it in M11 after the engine is e2e-validated.
const liveSyncEnabled = false;

/// Compile-time gate for the M7 background catch-up scheduler.
///
/// **LIVE since M7-E** (`docs/M7E_GO_LIVE_PLAN.md`). With the flag `true`:
/// - Android: `registerBackgroundCatchup()` registers the ~15-min WorkManager
///   periodic task from the FGS enable path, and every wake runs the worker
///   gate chain (flag → consent → pending-wipe → FGS-alive →
///   foreground-active → receive-only sweep) in
///   `background_catchup_worker.dart`.
/// - iOS: `writeCatchupEnabledMirror()` mirrors `true` to UserDefaults at
///   every launch, so the Swift handlers' `isEnabled()` predicate can arm
///   SLC monitoring + BGAppRefreshTask scheduling once the user enables
///   background sharing.
///
/// **Rollback = flip this back to `false`** (one-commit re-inert, plan §7):
/// registration stops, the iOS mirror rewrites `false` on the next launch,
/// and — because the Android worker re-checks this flag as gate 0 on EVERY
/// wake — an already-registered periodic task from a flag-ON build no-ops
/// cleanly even before `cancelBackgroundCatchup()` (deliberately
/// flag-independent) runs.
///
/// The consent chokepoints are unchanged and independent of this flag: the
/// user's durable background-sharing intent is re-checked at every wake
/// (worker gate 1 / Swift `isEnabled()`) and again inside
/// `CatchupService.runCatchup(isBackgroundWake: true)` (C3).
const bool backgroundCatchupEnabled = true;

/// The connection health of the live-sync engine, derived from the stream's
/// non-content [`FfiSyncStatusReason`] signals.
enum SyncConnectionPhase {
  /// No session started yet (engine off or pre-start).
  idle,

  /// Establishing / re-establishing relay connections.
  connecting,

  /// Connected and receiving.
  connected,

  /// A relay dropped; the engine is reconnecting.
  disconnected,
}

/// Immutable snapshot of the live-sync engine's status for the UI.
@immutable
class SyncStatus {
  /// Creates a status snapshot.
  const SyncStatus({required this.phase, this.lastIssue});

  /// The idle (no-session) status.
  static const idle = SyncStatus(phase: SyncConnectionPhase.idle);

  /// Current connection phase.
  final SyncConnectionPhase phase;

  /// The most recent non-fatal issue reason (a decrypt/relay/inbox error), or
  /// `null` if none has occurred since the last connection change. Surfaced for
  /// a future diagnostics indicator; never a hard failure.
  final FfiSyncStatusReason? lastIssue;

  /// Whether the engine is connected and healthy.
  bool get isConnected => phase == SyncConnectionPhase.connected;

  /// Returns a copy with the given overrides.
  SyncStatus copyWith({
    SyncConnectionPhase? phase,
    FfiSyncStatusReason? lastIssue,
    bool clearIssue = false,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    lastIssue: clearIssue ? null : (lastIssue ?? this.lastIssue),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncStatus &&
          runtimeType == other.runtimeType &&
          phase == other.phase &&
          lastIssue == other.lastIssue;

  @override
  int get hashCode => Object.hash(phase, lastIssue);
}

/// Holds the live-sync engine's [SyncStatus], fed by the subscription service's
/// `status` stream events.
final syncStatusProvider = NotifierProvider<SyncStatusNotifier, SyncStatus>(
  SyncStatusNotifier.new,
);

/// Notifier that maps each [FfiSyncStatusReason] to a [SyncStatus] transition.
class SyncStatusNotifier extends Notifier<SyncStatus> {
  @override
  SyncStatus build() => SyncStatus.idle;

  /// Records one status reason from the engine, transitioning the snapshot.
  ///
  /// Connection reasons move the phase; non-fatal issue reasons
  /// (`unprocessable`/`inboxError`/`relayError`) only record `lastIssue` without
  /// dropping the connected phase (a single undecryptable event is not an
  /// outage). `sessionStopped` resets to idle.
  void onStatus(FfiSyncStatusReason reason) {
    state = mapReason(state, reason);
  }

  /// Pure transition (testable without a runtime).
  static SyncStatus mapReason(SyncStatus current, FfiSyncStatusReason reason) {
    switch (reason) {
      case FfiSyncStatusReason.connecting:
      case FfiSyncStatusReason.sessionStarted:
        return current.copyWith(phase: SyncConnectionPhase.connecting);
      case FfiSyncStatusReason.connected:
      case FfiSyncStatusReason.backgroundResumed:
        return current.copyWith(
          phase: SyncConnectionPhase.connected,
          clearIssue: true,
        );
      case FfiSyncStatusReason.reconnecting:
        return current.copyWith(phase: SyncConnectionPhase.connecting);
      case FfiSyncStatusReason.disconnected:
        return current.copyWith(phase: SyncConnectionPhase.disconnected);
      case FfiSyncStatusReason.sessionStopped:
        return SyncStatus.idle;
      case FfiSyncStatusReason.unprocessable:
      case FfiSyncStatusReason.inboxError:
      case FfiSyncStatusReason.relayError:
        // A non-fatal issue: record it but keep the current connection phase.
        return current.copyWith(lastIssue: reason);
    }
  }

  /// Resets to idle (e.g. on logout).
  void reset() => state = SyncStatus.idle;
}
