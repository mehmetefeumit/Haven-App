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

/// Compile-time gate for the M7-A background catch-up scheduler.
///
/// While `false` (the default), **no native scheduler is registered**.
/// `disableBackgroundScheduling()` and the `CatchupService` chokepoint are
/// wired and tested, but the OS-level wakers (Android WorkManager, iOS
/// Significant-Location-Change, iOS BGAppRefreshTask) are never registered.
///
/// This is intentional: M7-A is "privacy teardown + scaffolding" only. The
/// teardown path must land before any scheduler is created so that the very
/// first scheduler registration already has a guaranteed cancel path.
///
/// Flips to `true` only after M7-B (Rust `WRITER_LOCK`), M7-C (Android
/// WorkManager), and M7-D (iOS SLC/BGTask) are fully reviewed and
/// device-validated — see `docs/M7_BACKGROUND_SHARING_PLAN.md §G`.
///
/// **Extension points for M7-C/D** (leave as no-ops here; activate there):
/// - Android: `Workmanager().cancelAll()` inside `disableBackgroundScheduling`.
/// - iOS: `stopSLC()` + `BGTaskScheduler.cancelAllTaskRequests()` via
///   MethodChannel inside `disableBackgroundScheduling`.
// ignore: avoid_redundant_argument_values
const bool backgroundCatchupEnabled = false;

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
