/// A ping/pong liveness probe between the Android foreground-service isolate
/// and the main (UI) isolate.
///
/// # Why a probe and not the foreground-active heartbeat
///
/// The background isolate already reads `kForegroundActiveAtMsKey` to decide
/// who owns *publishing*. That signal cannot answer the different question this
/// probe exists for — "is the main isolate still alive and holding the MLS
/// session?" — because `MapShell._onPaused` writes `0` on the Android handoff
/// path while deliberately keeping its `CircleManagerFfi` and its live-sync
/// engine. So `0` means "paused, alive, still holding the Rule-14 guard", and
/// it ALSO means "the Flutter engine was destroyed after a clean pause". Those
/// two states are indistinguishable in the timestamp, and demand opposite
/// actions: reclaiming the session is correct for the second and destroys a
/// healthy engine for the first.
///
/// A ping/pong distinguishes them directly: only a live isolate can answer.
///
/// # Fail-closed, with one deliberate exception
///
/// Silence past the timeout is the ONLY condition reported as "dead" — it is
/// the signal this class exists to produce. Every other failure — a send that
/// throws, a malformed reply, a reply for a stale nonce, a probe already in
/// flight — is reported as "alive", because the caller uses this to authorise a
/// destructive recovery step. A false "dead" tears down a working session; a
/// false "alive" only defers recovery to the next tick.
///
/// A single silent window is NOT sufficient evidence on its own: a garbage
/// collection or a slow frame in a perfectly healthy isolate can produce one.
/// The caller therefore requires two consecutive "dead" verdicts, and consumes
/// its rate limit whatever the verdict, so the number of chances to misread
/// stays bounded.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Key under which the service isolate sends its liveness ping to the main
/// isolate. The value is an opaque nonce echoed back in the reply.
const String kLivenessPingKey = 'haven.liveness.ping';

/// Key under which the main isolate echoes a ping's nonce back.
const String kLivenessPongKey = 'haven.liveness.pong';

/// How long the service isolate waits for a reply before concluding the main
/// isolate is gone.
///
/// Generous on purpose. The cost of waiting is one deferred recovery attempt;
/// the cost of timing out on a merely-busy isolate is a destroyed live-sync
/// engine. A slow reply cannot by itself trigger a reclaim: the caller requires
/// a second, independent timeout before acting.
const Duration kLivenessProbeTimeout = Duration(seconds: 5);

/// Gap between a probe and its confirmation.
///
/// Two probes issued back-to-back observe one contiguous window, so a single
/// sustained stall satisfies both and the confirmation proves nothing. This
/// separates them enough to be independent samples without stretching the whole
/// decision past a publish cycle.
const Duration kLivenessProbeGap = Duration(seconds: 3);

/// Registers the main-isolate side of the probe: reply to any ping with the
/// same nonce.
///
/// Call once during app startup, NOT from a widget. The responder must stay
/// installed for as long as this isolate could be holding the MLS session,
/// which outlives any particular route or widget mount.
///
/// Idempotent — a second call is ignored, so a hot restart cannot install two
/// responders that both answer the same ping.
void registerForegroundLivenessResponder() {
  if (_responderInstalled) return;
  _responderInstalled = true;
  FlutterForegroundTask.addTaskDataCallback(_respondToPing);
}

bool _responderInstalled = false;

void _respondToPing(Object data) {
  if (data is! Map) return;
  final Object? nonce = data[kLivenessPingKey];
  if (nonce == null) return;
  try {
    FlutterForegroundTask.sendDataToTask(<String, Object>{
      kLivenessPongKey: nonce,
    });
  } on Object catch (e) {
    // Nothing to recover here: a failed reply reads as "no reply", which the
    // service treats as "possibly alive" and therefore declines to reclaim.
    debugPrint('[Liveness] reply failed: ${e.runtimeType}');
  }
}

/// The service-isolate side of the probe.
///
/// Owned by the task handler, which routes incoming data to [onData] and calls
/// [mainIsolateIsAlive] before authorising a session reclaim.
class ForegroundLivenessProbe {
  Completer<void>? _pending;
  int _nextNonce = 1;

  /// Nonces issued recently, not just the one in flight.
  ///
  /// A reply that arrives after its own probe gave up is still direct proof
  /// that the main isolate is alive and answering — discarding it (as matching
  /// a single `_nonce` did) meant a sustained stall spanning both probes read
  /// as death, which is the verdict that authorises tearing down a session.
  /// The realistic cause is not jank but the main isolate blocked on a sync FFI
  /// call while this isolate holds the same SQLCipher locks — i.e. exactly the
  /// situation this runs in.
  final Set<int> _recentNonces = <int>{};

  /// Set when a reply lands for any recently-issued nonce. [sawRecentReply]
  /// lets the caller abandon a reclaim it has already started deciding on.
  bool _sawReply = false;

  /// Whether the main isolate answered ANY recent probe, including one whose
  /// own wait had already elapsed.
  bool get sawRecentReply => _sawReply;

  /// Forgets prior probes. Call before a fresh decision so a reply from an
  /// earlier, unrelated round cannot vouch for the isolate now.
  void resetRound() {
    _recentNonces.clear();
    _sawReply = false;
  }

  /// Feeds a payload received by the task handler to this probe.
  ///
  /// Returns `true` if the payload was a reply to the in-flight ping, so the
  /// caller can tell probe traffic from application traffic.
  bool onData(Object data) {
    if (data is! Map) return false;
    final Object? nonce = data[kLivenessPongKey];
    if (nonce == null) return false;
    // Only nonces from THIS round count — a reply from an earlier, unrelated
    // decision says nothing about the isolate now.
    if (!_recentNonces.contains(nonce)) return true;
    _sawReply = true;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.complete();
    }
    return true;
  }

  /// Whether the main isolate answered within [kLivenessProbeTimeout].
  ///
  /// Fails CLOSED: returns `true` ("assume alive") on any error, because the
  /// caller uses this to authorise tearing down a session it may not own.
  Future<bool> mainIsolateIsAlive({
    Duration timeout = kLivenessProbeTimeout,
  }) async {
    if (_pending != null) {
      // A concurrent probe would overwrite `_nonce`, so the earlier call's
      // correctly-timed reply would then look stale and be ignored — making it
      // time out and report "dead", the dangerous direction. Today the single
      // caller is serialised by the task handler's in-flight check; this keeps
      // the class safe if that ever stops being true.
      debugPrint('[Liveness] probe already in flight; assuming alive');
      return true;
    }
    final nonce = _nextNonce++;
    _recentNonces.add(nonce);
    final pending = Completer<void>();
    _pending = pending;
    try {
      FlutterForegroundTask.sendDataToMain(<String, Object>{
        kLivenessPingKey: nonce,
      });
    } on Object catch (e) {
      debugPrint('[Liveness] ping send failed: ${e.runtimeType}');
      _pending = null;
      return true;
    }
    try {
      await pending.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } on Object catch (e) {
      debugPrint('[Liveness] probe failed: ${e.runtimeType}');
      return true;
    } finally {
      _pending = null;
    }
  }
}
