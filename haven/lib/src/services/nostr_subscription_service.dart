import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/subscription_service.dart';

/// The Rust-backed [SubscriptionService]: builds a [LiveSyncFfi] engine, starts
/// the session, and feeds `liveEvents()` to a [LiveEventRouter] for the session
/// lifetime.
///
/// Events are processed SEQUENTIALLY (chained onto an internal future) so a
/// `GroupUpdate` roster reconcile can never interleave with a concurrent
/// `Location` ingest for the same circle — matching the pollers' one-at-a-time
/// processing. The engine bus already delivers in order; this preserves that
/// order through the async handlers.
class NostrSubscriptionService implements SubscriptionService {
  /// Creates the service over a [LiveEventRouter] and an engine factory
  /// (`LiveSyncFfi.newInstance(...)`); the factory is injected so the FFI build
  /// is isolated from the testable routing.
  NostrSubscriptionService({
    required LiveEventRouter router,
    required Future<LiveSyncFfi> Function() engineFactory,
    this.onStopOutcome,
  }) : _router = router,
       _engineFactory = engineFactory;

  final LiveEventRouter _router;
  final Future<LiveSyncFfi> Function() _engineFactory;

  /// Notified with the result of every [stop].
  ///
  /// [stop] already RETURNS the outcome, so this exists for the stops no caller
  /// awaits: the failed-start cleanup and `_onStreamClosed`'s
  /// `unawaited(stop())`. A stop that leaves the guard held is exactly as
  /// serious there as on the pause path, and without this it would be visible
  /// only in a debug log.
  final void Function(LiveSyncStopOutcome)? onStopOutcome;

  LiveSyncFfi? _engine;
  StreamSubscription<FfiRelayEvent>? _sub;

  /// Whether the last [stop] left the engine still holding the Rule-14 guard.
  ///
  /// [stop] clears `_engine` before it returns, so a SECOND stop finds nothing
  /// to stop and would answer [LiveSyncStopOutcome.idle] — "nothing was holding
  /// anything" — while the wedged core Rust reinstalled into `SESSION` still
  /// owns the guard. The pause path reads that answer to decide whether to
  /// dispose its own manager, so an unlatched `stillHolding` becomes an
  /// orphaned guard one pause later: exactly the wedge this all exists to stop.
  ///
  /// Cleared only by a successful [start], which is the one event that PROVES
  /// the wedge is gone — Rust's `start_session` fails closed ("previous live
  /// session did not stop; refusing to start a second") unless the previous
  /// core actually drained.
  bool _stopLeftGuardHeld = false;

  /// Serializes the async event handlers: each [LiveEventRouter.handleEvent] is
  /// chained after the previous one completes.
  Future<void> _processing = Future<void>.value();

  @override
  bool get isRunning {
    try {
      return _engine?.isRunning() ?? false;
    } on Object catch (_) {
      return false;
    }
  }

  @override
  bool get isPaused {
    try {
      return _engine?.isPaused() ?? false;
    } on Object catch (e) {
      // `false` is the answer a failed read must give, but it is fail-safe
      // only for the callers that re-anchor on it (`_ensureRunning`,
      // `_fullRestart`). `MapShell.reanchorOnResume` reads it as "no second
      // re-anchor needed" and would leave a paused engine live in the
      // foreground. Either way it is indistinguishable from a genuine
      // un-paused session, so the read failing at all has to be visible
      // somewhere. The type only; the FFI message is remote text (Rule 8).
      debugPrint('[Subscription] isPaused read failed: ${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {
    if (_engine != null) return; // idempotent
    // Held outside the try so the failure path can release it. Until this
    // handle is disposed it keeps an `Arc<CircleManager>` alive, and with it the
    // MLS database's Rule-14 `LiveSessionGuard` — so a leak here does not just
    // waste memory, it makes the database unopenable. Relying on the native
    // finalizer is not enough: it runs on GC, which is non-deterministic and may
    // never happen.
    LiveSyncFfi? built;
    try {
      final engine = await _engineFactory();
      built = engine;
      await engine.startSession(groups: groups, inboxRelays: inboxRelays);
      _engine = engine;
      // A session that started is proof the previous core drained (Rust refuses
      // to install a second over a live one), so the wedge latch is discharged.
      _stopLeftGuardHeld = false;
      // Ownership has transferred to `_engine`; `stop()` disposes it from here
      // on, so the failure path below must NOT also dispose it.
      built = null;
      // Subscribe only AFTER startSession resolves — `liveEvents()` throws on a
      // cold-start race (no active session yet).
      _sub = engine.liveEvents().listen(
        _enqueue,
        onError: (Object e, StackTrace _) {
          debugPrint('[Subscription] stream error: ${e.runtimeType}');
        },
        onDone: _onStreamClosed,
        cancelOnError: false,
      );
    } on Object catch (e) {
      // Type only, in every build: `redact_hex_sequences` only collapses long
      // hex runs, so an MLS group id embedded at a shorter width — or an
      // npub, relay URL or display name — would pass through a raw `$e'
      // untouched (Security Rule 8/15). No debug/e2e-only detail line either;
      // a debug capture is still a capture.
      debugPrint('[Subscription] start failed: ${e.runtimeType}');
      await stop();
      // `stop()` cannot reach this handle: `_engine` is only assigned once
      // `startSession` has resolved, so a throw before that leaves the engine
      // referenced by nothing but this local. Dropping it here is what keeps a
      // failing start from stranding the guard — and the self-heal retries
      // every couple of minutes, so a persistent failure would otherwise
      // accumulate one guard holder per attempt and permanently block both the
      // foreground service's reclaim and its own next retry.
      try {
        built?.dispose();
      } on Object catch (e) {
        debugPrint('[Subscription] failed-start dispose: ${e.runtimeType}');
      }
      throw const SubscriptionServiceException('failed to start live session');
    }
  }

  /// Handles the event stream ending without [stop] having asked for it.
  ///
  /// The stream completes when the engine's native bus closes, so this means
  /// the session ended underneath us — a Rust-side teardown, or another isolate
  /// force-releasing the process-global session to reclaim the MLS database.
  ///
  /// Two things were broken without this. The service kept a non-null `_engine`,
  /// and [start] early-returns while that is set, so live receive stayed dead
  /// for the rest of the process — nothing else restarts it, since the only
  /// existing restart path fires on a change to the accepted-circle set. And the
  /// dead handle was never disposed, so its `Arc<CircleManager>` clone kept the
  /// Rule-14 `LiveSessionGuard` registered — which is what a reclaiming isolate
  /// is waiting on, so the death held the database hostage as well.
  ///
  /// Running the normal teardown restores a clean, restartable state and drops
  /// the handle. It does NOT restart here: this callback cannot know the group
  /// set or whether a session is still wanted. Recovery is the owner's job (see
  /// `LiveSyncResubscriber.ensureRunning`).
  void _onStreamClosed() {
    // A null `_engine` means WE are the ones closing the bus. [stop] clears the
    // field synchronously, before the `await engine.stopSession()` that ends the
    // stream, so its own `onDone` always observes null and this returns — no
    // re-entrant teardown, and no separate "am I stopping" flag to keep in step.
    //
    // That ordering is therefore load-bearing, not incidental: moving the clear
    // after `stopSession()` would make every deliberate stop re-enter itself.
    // `a deliberate stop is not mistaken for a death` pins it.
    if (_engine == null) return;
    debugPrint('[Subscription] event stream closed unexpectedly — releasing');
    unawaited(stop());
  }

  /// Chains the next event's handler after the in-flight one (serialized). The
  /// router never throws (every side effect is guarded), but the `catchError`
  /// is a defensive backstop so a stray error can never break the chain.
  void _enqueue(FfiRelayEvent event) {
    _processing = _processing
        .then((_) => _router.handleEvent(event))
        .catchError((Object e) {
          debugPrint('[Subscription] event handler error: ${e.runtimeType}');
        });
  }

  @override
  Future<void> resumeAfterBackground() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.resumeAfterBackground();
    } on Object catch (e) {
      debugPrint('[Subscription] resume failed: ${e.runtimeType}');
    }
  }

  /// Unlike [resumeAfterBackground], this THROWS on failure.
  ///
  /// A foreground re-anchor is one of several redundant repairs — the health
  /// tick and the next app resume both retry it — so swallowing there costs
  /// nothing. A burst open has no redundancy: if it fails, this burst holds no
  /// subscription, and a caller that went on to wait for a backlog nobody
  /// requested would spend the whole wait budget to learn nothing.
  @override
  Future<void> openBackgroundBurst() async {
    final engine = _engine;
    if (engine == null) {
      throw const SubscriptionServiceException('no active live session');
    }
    try {
      await engine.openBackgroundBurst();
    } on Object catch (e) {
      debugPrint('[Subscription] burst open failed: ${e.runtimeType}');
      throw const SubscriptionServiceException('failed to open burst');
    }
  }

  /// How many long-lived subscriptions the engine pool holds right now, across
  /// every relay — the DIRECT read of the background-burst promise "no standing
  /// REQ between publish ticks".
  ///
  /// [isPaused] cannot stand in for it, and an oracle built on that flag is the
  /// specific mistake this method exists to prevent: the engine raises it as
  /// the FIRST statement of its pause — before `unsubscribe_all`, before the
  /// router drain, before the uncapped Rule-13 publish gauge and before the
  /// disconnect — so it reports that the pause was ENTERED, not that the REQs
  /// are gone. The flag asserts an intent; this asserts the state.
  ///
  /// THROWS when there is no session, and deliberately never answers `0` for
  /// one: zero is the PASSING value of the promise, so "there was nothing to
  /// ask" must not be readable as "nothing is standing".
  ///
  /// Not on [SubscriptionService]: no production caller decides anything from
  /// it, and the two that read [isPaused] must keep reading that. Its one
  /// caller is the `e2e-ios-background-publish` drive, which already narrows to
  /// this type to prove the production path was not bypassed.
  ///
  /// Test-only, so annotated — but deliberately NOT renamed to the repo's
  /// `…ForTest` convention (`LocationSharingService.trackCommitCriticalForTest`
  /// carries both). Two things pin this spelling: it is the FFI method's own
  /// name one layer down, and `check_ios_background_publish.sh` requires the
  /// drive to read `poolSubscriptionCount(` verbatim — the guard that stops
  /// the drive's oracle from being swapped for the engine's paused flag, which
  /// would go green through every state it exists to catch. Renaming means
  /// re-pointing that guard in the same commit.
  @visibleForTesting
  Future<int> poolSubscriptionCount() async {
    final engine = _engine;
    if (engine == null) {
      throw const SubscriptionServiceException('no active live session');
    }
    try {
      return await engine.poolSubscriptionCount();
    } on Object catch (e) {
      // Rule 8: the type only — the FFI message is a Rust `Result` string.
      debugPrint('[Subscription] pool count read failed: ${e.runtimeType}');
      throw const SubscriptionServiceException(
        'failed to read the pool subscription count',
      );
    }
  }

  /// A missing session or a failed wait answers [BacklogOutcomeFfi.timedOut] —
  /// the outcome that promises nothing. Answering `settled` would tell the
  /// caller every endpoint had replayed when none was even asked, and the
  /// caller would encrypt at an epoch a peer commit may already have moved.
  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async {
    final engine = _engine;
    if (engine == null) return BacklogOutcomeFfi.timedOut;
    try {
      return await engine.waitBacklogSettled();
    } on Object catch (e) {
      debugPrint('[Subscription] backlog wait failed: ${e.runtimeType}');
      return BacklogOutcomeFfi.timedOut;
    }
  }

  @override
  Future<void> settleBeforePause() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.settleBeforePause();
    } on Object catch (e) {
      debugPrint('[Subscription] settle failed: ${e.runtimeType}');
    }
  }

  /// Best-effort, and deliberately non-throwing: this is the caller's `finally`
  /// link, so a throw here would REPLACE whatever failure aborted the burst
  /// with a less informative one.
  ///
  /// A failure is therefore invisible to the caller beyond the log, and
  /// [isPaused] does not close that gap: the engine raises its flag as the
  /// first statement of the pause, so it answers `true` for a pause that only
  /// half-completed exactly as it does for one that finished, and `false` both
  /// for "there was no session to pause" and for an FFI read that threw. The
  /// recovery is the next burst, which re-anchors from the stored live set
  /// whatever state this left behind.
  @override
  Future<void> pauseSubscriptions() async {
    final engine = _engine;
    if (engine == null) return;
    try {
      await engine.pauseSubscriptions();
    } on Object catch (e) {
      debugPrint('[Subscription] pause failed: ${e.runtimeType}');
    }
  }

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async {
    final engine = _engine;
    if (engine == null) {
      throw const SubscriptionServiceException('no active live session');
    }
    try {
      await engine.subscribeCircle(spec: spec);
    } on Object catch (e) {
      debugPrint('[Subscription] subscribeCircle failed: ${e.runtimeType}');
      throw const SubscriptionServiceException('failed to subscribe circle');
    }
  }

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async {
    final engine = _engine;
    if (engine == null) {
      throw const SubscriptionServiceException('no active live session');
    }
    try {
      await engine.unsubscribeCircle(nostrGroupId: nostrGroupId);
    } on Object catch (e) {
      debugPrint('[Subscription] unsubscribeCircle failed: ${e.runtimeType}');
      throw const SubscriptionServiceException('failed to unsubscribe circle');
    }
  }

  /// Bounds the defensive `_sub.cancel()` below — best-effort only, since by
  /// the time it runs `stopSession()` has already closed the native bus and
  /// the cancel is expected to be a near-instant no-op.
  static const Duration _cancelTimeout = Duration(seconds: 2);

  /// Stops the engine, retrying ONCE if the first attempt did not drain.
  ///
  /// A failed `stopSession()` is not a lost call: Rust reinstalls the
  /// timed-out core into the process-global `SESSION` precisely so a retry has
  /// something to stop (`rust_builder/src/api.rs`
  /// `reinstall_after_timed_out_stop`), and a second call re-takes it and
  /// re-joins the SAME outstanding supervisor handles under a fresh budget. So
  /// the retry is not a hopeful repeat of an identical operation — it is a
  /// second, later join of tasks that were merely still finishing, and it is
  /// the last chance anything gets: once this method returns, no Dart handle in
  /// any isolate references that core.
  Future<LiveSyncStopOutcome> _stopEngineWithRetry(LiveSyncFfi engine) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await engine.stopSession();
        return LiveSyncStopOutcome.stopped;
      } on Object catch (e) {
        debugPrint(
          '[Subscription] stop attempt $attempt failed: ${e.runtimeType}',
        );
      }
    }
    return LiveSyncStopOutcome.stillHolding;
  }

  @override
  Future<LiveSyncStopOutcome> stop() async {
    // Reset the serialized chain so a subsequent start() begins clean: any old
    // in-flight handlers still run to completion on their own reference, but the
    // NEXT session's events do not chain behind the previous session's.
    _processing = Future<void>.value();
    final engine = _engine;
    _engine = null;
    // ORDERING IS LOAD-BEARING: stopSession() MUST run before _sub.cancel().
    // `_sub` subscribes to `engine.liveEvents()`, a flutter_rust_bridge
    // StreamSink whose native task loop only ends when the underlying event
    // bus closes — which happens as part of stopSession()'s teardown. If we
    // cancelled `_sub` first (as this used to), `_sub.cancel()` would await
    // FRB's native-side cancellation, which awaits that same task ending,
    // which awaits the bus close performed by stopSession() — a call we
    // hadn't made yet. That is an ordering deadlock, not a hang inside Rust.
    // Calling stopSession() first lets the native task end (and the Dart
    // stream complete) BEFORE we ever cancel, so the cancel below becomes a
    // trivial no-op on an already-closed stream.
    var outcome = LiveSyncStopOutcome.idle;
    if (engine != null) {
      outcome = await _stopEngineWithRetry(engine);
      if (outcome == LiveSyncStopOutcome.stillHolding) {
        _stopLeftGuardHeld = true;
      }
    } else if (_stopLeftGuardHeld) {
      // No handle left to stop, but the guard was never released — report the
      // state, not the absence of work.
      outcome = LiveSyncStopOutcome.stillHolding;
    }
    try {
      // Defensive bound: even if some other holder keeps the native task
      // alive despite stopSession() above, teardown must never hang on this
      // cancel — best-effort only, so any error/timeout is swallowed.
      await _sub?.cancel().timeout(_cancelTimeout);
    } on Object catch (_) {
      // ignore — tearing down anyway
    }
    _sub = null;
    // Release the engine handle's RustOpaque Arc deterministically, LAST — it
    // holds its own `Arc<CircleManager>` clone, so until it drops, the MLS
    // DB's Rule-14 `LiveSessionGuard` stays held and the next open of the same
    // `session.sqlite` fails closed. Nulling `_engine` above only makes it
    // GC-eligible; `dispose()` drops it now. Deliberately after the stream
    // cancel so the load-bearing stopSession()-then-cancel ordering documented
    // above is untouched, and a `start()` after this always builds a fresh
    // engine via `_engineFactory` rather than reusing a disposed handle.
    // Guarded like every other fallible step here. Disposing an FRB opaque
    // handle right after an ABNORMAL engine death is exactly where a Rust-side
    // drop could fail, and this method is reached from `unawaited(stop())` in
    // `_onStreamClosed` — so an escape would surface as an unhandled async
    // error with no caller able to catch it.
    try {
      engine?.dispose();
    } on Object catch (e) {
      debugPrint('[Subscription] engine dispose failed: ${e.runtimeType}');
    }
    // Reported AFTER the dispose so an observer never sees "stopped" while the
    // handle is still alive. Guarded like every other step: this method is
    // reached from `unawaited(stop())`, where a throw has no caller to catch
    // it.
    try {
      onStopOutcome?.call(outcome);
    } on Object catch (e) {
      debugPrint('[Subscription] stop-outcome callback: ${e.runtimeType}');
    }
    return outcome;
  }
}
