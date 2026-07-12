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
  }) : _router = router,
       _engineFactory = engineFactory;

  final LiveEventRouter _router;
  final Future<LiveSyncFfi> Function() _engineFactory;

  LiveSyncFfi? _engine;
  StreamSubscription<FfiRelayEvent>? _sub;

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
    try {
      final engine = await _engineFactory();
      await engine.startSession(groups: groups, inboxRelays: inboxRelays);
      _engine = engine;
      // Subscribe only AFTER startSession resolves — `liveEvents()` throws on a
      // cold-start race (no active session yet).
      _sub = engine.liveEvents().listen(
        _enqueue,
        onError: (Object e, StackTrace _) {
          debugPrint('[Subscription] stream error: ${e.runtimeType}');
        },
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
      throw const SubscriptionServiceException('failed to start live session');
    }
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
  Future<void> stop() async {
    // Reset the serialized chain so a subsequent start() begins clean: any old
    // in-flight handlers still run to completion on their own reference, but the
    // NEXT session's events do not chain behind the previous session's.
    _processing = Future<void>.value();
    try {
      await _sub?.cancel();
    } on Object catch (_) {
      // ignore — tearing down anyway
    }
    _sub = null;
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      try {
        await engine.stopSession();
      } on Object catch (e) {
        debugPrint('[Subscription] stop failed: ${e.runtimeType}');
      }
    }
  }
}
