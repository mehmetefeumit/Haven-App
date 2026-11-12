/// Own-profile local-outbox sync trigger and foreground retry timer.
///
/// Local saves ([ProfileService.updateOwnProfile], [ProfileService
/// .setOwnAvatar], [ProfileService.removeOwnAvatar]) land on the local cache
/// in milliseconds and touch no relay. [ProfileService.syncOwnProfile] is what
/// actually publishes, and this notifier is the ONE place in the widget
/// layer that calls it, so overlapping triggers (a name edit landing beside
/// a resume trigger, say) coalesce into a single relay round trip instead of
/// each opening its own connections for the same publish — mirrors
/// `MemberProfileRefreshNotifier`'s `_inFlight`/queued shape
/// (`member_profile_refresh_provider.dart`). The UI renders no publish state;
/// this notifier holds none.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/profile_service.dart';

/// Notifier owning the own-profile sync trigger and its one retry timer.
///
/// Non-autoDispose (the `MemberProfileRefreshNotifier` precedent): [sync]
/// starts a fire-and-forget `Future`, so the notifier must not be disposable
/// mid-flight — e.g. a user navigating away from the Identity page while a
/// publish is still in flight.
///
/// The timer re-attempts a save the persisted ladder is still waiting on, and
/// runs only while the app is resumed: the main isolate stays alive under the
/// Android foreground service and the iOS location session, so a timer
/// surviving a pause would dial relays from a backgrounded process. A bare
/// [WidgetsBindingObserver] rather than `AppLifecycleListener`, which asserts
/// on real Android transitions (see `AppForegroundNotifier`).
class OwnProfileSyncController extends Notifier<void>
    with WidgetsBindingObserver {
  /// Whether a sync is currently in flight.
  bool _inFlight = false;

  /// Whether a follow-up sync is queued because [sync] was called again
  /// while [_inFlight].
  bool _queued = false;

  /// Set once this notifier is torn down, so a stale in-flight task stops.
  bool _disposed = false;

  Timer? _timer;

  /// Whether the current failure streak has had its one fallback retry; reset
  /// by a pass that completes and by a resume.
  bool _failureRetryArmed = false;

  /// Whether the fallback fired while a pass was in flight, and is honoured
  /// when that pass settles instead of being spent on a no-op.
  bool _fallbackOwed = false;

  /// The wait before the one retry after a pass that threw while the ladder
  /// still reads due — a throw before Rust recorded an attempt.
  static const _failureRetryDelay = Duration(seconds: 30);

  @override
  void build() {
    _inFlight = false;
    _queued = false;
    _disposed = false;
    _failureRetryArmed = false;
    _fallbackOwed = false;
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() {
      _disposed = true;
      _timer?.cancel();
      _timer = null;
      WidgetsBinding.instance.removeObserver(this);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      _failureRetryArmed = false;
      // map_shell's resume handler returns on its debounce before its own
      // retry trigger, so without this a brief app switch would cancel the
      // timer and never re-arm it.
      unawaited(retryIfPending());
    } else {
      _timer?.cancel();
      _timer = null;
      _fallbackOwed = false;
    }
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
    try {
      await ref.read(profileServiceProvider).syncOwnProfile();
      _failureRetryArmed = false;
      if (_disposed) return;
      await _arm();
    } on Object catch (e) {
      // Rule 8: never surface raw text.
      debugPrint('[Profile] sync failed: ${e.runtimeType}');
      if (!_disposed) await _arm(afterFailure: true);
    } finally {
      _inFlight = false;
      final queued = _queued;
      final owed = _fallbackOwed;
      _queued = false;
      // A queued pass is itself the attempt the fallback was for.
      _fallbackOwed = false;
      if (queued && !_disposed) {
        unawaited(sync());
      } else if (owed && !_disposed) {
        unawaited(retryIfPending());
      }
    }
  }

  /// Consults the persisted backoff and syncs ONLY when a save is pending AND
  /// the ladder permits another attempt now — never unconditionally (relay
  /// metadata minimization). This is the resume/cold-start/timer entry point.
  ///
  /// When pending but not yet due it arms the retry timer instead. While a
  /// sync is in flight it does nothing: it neither starts nor queues another,
  /// and that pass arms the timer itself when it ends.
  Future<void> retryIfPending() => _retryIfPending();

  Future<void> _retryIfPending({bool fallback = false}) async {
    if (_disposed) return;
    final ProfilePendingState pendingState;
    try {
      pendingState = await ref.read(profileServiceProvider).pendingSyncState();
    } on Object catch (e) {
      // Defensive only: pendingSyncState already fails closed and never
      // throws; a non-conforming implementation still arms nothing.
      debugPrint(
        '[Profile] retryIfPending: pendingSyncState failed: ${e.runtimeType}',
      );
      return;
    }
    if (_disposed) return;
    if (_inFlight) {
      // That pass, if it throws too, finds the streak's fallback spent and
      // arms nothing, so the fallback is held for when it settles — unless
      // the app was paused during the read above, which drops it.
      if (fallback &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _fallbackOwed = true;
      }
      return;
    }
    if (pendingState.pending && pendingState.retryDue) {
      await sync();
      return;
    }
    _armFrom(pendingState);
  }

  /// Re-reads the outbox after a pass and arms (or clears) the timer.
  Future<void> _arm({bool afterFailure = false}) async {
    try {
      _armFrom(
        await ref.read(profileServiceProvider).pendingSyncState(),
        afterFailure: afterFailure,
      );
    } on Object catch (e) {
      debugPrint('[Profile] arm: pendingSyncState failed: ${e.runtimeType}');
    }
  }

  /// The one timer: armed only for a pending save, and only while resumed.
  /// A not-due save waits out the ladder; a state still due arms nothing (no
  /// tight loop), except once per failure streak [afterFailure]: a throw
  /// before Rust recorded an attempt leaves the ladder due, and nothing else
  /// would retry before the next resume.
  void _armFrom(ProfilePendingState s, {bool afterFailure = false}) {
    // A queued pass that throws too must not cancel the streak's one fallback:
    // the flag says it is spent, so nothing below would arm another.
    if (afterFailure &&
        _failureRetryArmed &&
        _timer != null &&
        s.pending &&
        s.retryDue) {
      return;
    }
    _timer?.cancel();
    _timer = null;
    if (_disposed ||
        !s.pending ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    final int wait;
    final fallback = s.retryDue;
    if (!s.retryDue) {
      final next = s.nextRetryInSecs;
      if (next == null) return;
      wait = next;
    } else if (afterFailure && !_failureRetryArmed) {
      _failureRetryArmed = true;
      wait = _failureRetryDelay.inSeconds;
    } else {
      return;
    }
    _timer = Timer(Duration(seconds: wait < 1 ? 1 : wait), () {
      _timer = null;
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      unawaited(_retryIfPending(fallback: fallback));
    });
  }
}

/// Provider owning the own-profile sync trigger and retry timer.
final ownProfileSyncProvider =
    NotifierProvider<OwnProfileSyncController, void>(
      OwnProfileSyncController.new,
    );
