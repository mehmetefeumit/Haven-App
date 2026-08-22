/// Own-profile local-outbox sync trigger and the status the UI renders.
///
/// Local saves ([ProfileService.updateOwnProfile], [ProfileService
/// .setOwnAvatar]) merge onto the local cache and return in milliseconds —
/// they no longer touch a relay. [ProfileService.syncOwnProfile] is what
/// actually publishes, and this notifier is the ONE place in the widget
/// layer that calls it, so overlapping triggers (a name edit landing beside
/// a resume trigger, say) coalesce into a single relay round trip instead of
/// each opening its own connections for the same publish — mirrors
/// `MemberProfileRefreshNotifier`'s `_inFlight`/queued shape
/// (`member_profile_refresh_provider.dart`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

/// What the UI may honestly say about the own profile's publish state.
enum ProfileSyncStatus {
  /// The first local read has not resolved yet. Renders NOTHING — never
  /// claim "up to date" before this settles.
  unknown,

  /// A sync pass is currently running.
  syncing,

  /// Something has published to at least one relay, but not the whole pool
  /// (or a newer edit landed mid-flight) — still pending.
  partial,

  /// Every relay in the pool has acknowledged the current version.
  synced,

  /// The last sync attempt could not publish at all (upload/publish
  /// failure, or too few relays survive), and the persisted backoff is not
  /// due yet — or the local outbox itself could not be read.
  failed,
}

/// Notifier owning the own-profile sync trigger and the [ProfileSyncStatus]
/// the UI renders.
///
/// One shared status for the WHOLE own profile — not one per field — BY
/// DESIGN: a name edit and a photo edit both land in the same kind-0 event,
/// so there is exactly one publish state to report (see
/// `widgets/identity/profile_sync_status_line.dart`).
///
/// Non-autoDispose (the `MemberProfileRefreshNotifier` precedent): [sync]
/// starts a fire-and-forget `Future` that later assigns `state`, so the
/// notifier must not be disposable mid-flight — e.g. a user navigating away
/// from the Identity page while a publish is still in flight.
class OwnProfileSyncController extends Notifier<ProfileSyncStatus> {
  /// Whether a sync is currently in flight.
  bool _inFlight = false;

  /// Whether a follow-up sync is queued because [sync] was called again
  /// while [_inFlight].
  bool _queued = false;

  /// Set once this notifier is torn down. Checked before every `state`
  /// assignment so a stale in-flight task can never write to a disposed
  /// notifier.
  bool _disposed = false;

  @override
  ProfileSyncStatus build() {
    _inFlight = false;
    _queued = false;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // Resolve whatever the local outbox already holds (a save queued in a
    // prior session, or nothing) without forcing a network round trip up
    // front — retryIfPending() itself decides whether the backoff permits a
    // sync.
    unawaited(retryIfPending());
    return ProfileSyncStatus.unknown;
  }

  /// Runs one sync pass, coalescing overlapping calls into at most one
  /// queued follow-up (mirrors `MemberProfileRefreshNotifier.refreshRoster`).
  ///
  /// Always attempts the network — callers that should honour the
  /// persisted backoff instead (a resume/cold-start trigger) must call
  /// [retryIfPending], not this directly.
  Future<void> sync() async {
    if (_disposed) return;
    if (_inFlight) {
      _queued = true;
      return;
    }
    _inFlight = true;
    state = ProfileSyncStatus.syncing;
    try {
      final service = ref.read(profileServiceProvider);
      final result = await service.syncOwnProfile();
      if (_disposed) return;
      state = await _resolveAfterSync(service, result);
    } on Object catch (e) {
      // Rule 8: never surface raw text — the status enum carries no message.
      debugPrint('[Profile] sync failed: ${e.runtimeType}');
      if (!_disposed) state = ProfileSyncStatus.failed;
    } finally {
      _inFlight = false;
      final queued = _queued;
      _queued = false;
      if (queued && !_disposed) {
        unawaited(sync());
      }
    }
  }

  /// Consults the persisted pending/partial/backoff state and syncs ONLY
  /// when a save is pending AND the backoff permits another attempt now —
  /// never unconditionally (relay metadata minimization). This is the
  /// resume/cold-start entry point (`utils/profile_sync_trigger.dart`'s
  /// `triggerProfileSyncRetry`).
  ///
  /// When pending but not yet due, resolves the resting `partial`/`failed`
  /// state without touching the network.
  Future<void> retryIfPending() async {
    if (_disposed) return;
    final service = ref.read(profileServiceProvider);
    final ProfilePendingState pendingState;
    try {
      pendingState = await service.pendingSyncState();
    } on Object catch (e) {
      // Defensive only: ProfileService.pendingSyncState already fails closed
      // and documents that it never throws — this branch exists so a
      // non-conforming implementation still cannot claim "up to date".
      debugPrint(
        '[Profile] retryIfPending: pendingSyncState failed: ${e.runtimeType}',
      );
      if (!_disposed) state = ProfileSyncStatus.failed;
      return;
    }
    if (_disposed) return;
    if (!pendingState.pending) {
      state = ProfileSyncStatus.synced;
      return;
    }
    if (pendingState.retryDue) {
      await sync();
      return;
    }
    state = pendingState.partial
        ? ProfileSyncStatus.partial
        : ProfileSyncStatus.failed;
  }

  /// Maps one sync pass's [result] to the resting [ProfileSyncStatus].
  ///
  /// Distinguishes WHY a [ProfileSyncOutcome.published] pass is still
  /// pending: full relay-pool coverage with a newer edit landed mid-flight
  /// queues exactly one immediate follow-up (via [_queued], drained by
  /// [sync]'s `finally`); merely partial coverage does not — the persisted
  /// backoff, not an immediate retry, is what re-attempts that one (relay
  /// metadata minimization — an unreachable/slow relay must not turn into a
  /// tight retry loop).
  Future<ProfileSyncStatus> _resolveAfterSync(
    ProfileService service,
    ProfileSyncResult result,
  ) async {
    switch (result.outcome) {
      case ProfileSyncOutcome.published:
        final fullyAcked =
            result.relaysAttempted > 0 &&
            result.relaysAcked >= result.relaysAttempted;
        if (fullyAcked && !result.stillPending) {
          return ProfileSyncStatus.synced;
        }
        if (fullyAcked && result.stillPending) {
          _queued = true;
        }
        return ProfileSyncStatus.partial;
      case ProfileSyncOutcome.uploadFailed:
      case ProfileSyncOutcome.publishFailed:
      case ProfileSyncOutcome.poolUnderflow:
        return ProfileSyncStatus.failed;
      case ProfileSyncOutcome.nothingPending:
        final pendingState = await service.pendingSyncState();
        if (!pendingState.pending) return ProfileSyncStatus.synced;
        return pendingState.partial
            ? ProfileSyncStatus.partial
            : ProfileSyncStatus.failed;
    }
  }
}

/// Provider owning the own-profile sync trigger and status.
final ownProfileSyncProvider =
    NotifierProvider<OwnProfileSyncController, ProfileSyncStatus>(
      OwnProfileSyncController.new,
    );
