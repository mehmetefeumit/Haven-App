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
      debugPrint('[Subscription] start failed: ${e.runtimeType}');
      // The underlying FFI error is a Rust `Result` string already sanitized by
      // `redact_hex_sequences`; surface its (redacted) detail in debug/e2e builds
      // so an engine-start failure is diagnosable, not an opaque "String" type
      // (the wrapper thrown below otherwise hides it from MapShell).
      if (kDebugMode) {
        debugPrint('[Subscription] start error detail: $e');
      }
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
