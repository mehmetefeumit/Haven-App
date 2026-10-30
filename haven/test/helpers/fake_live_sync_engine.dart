/// The fake live-sync engine shared by every test that drives the real
/// `NostrSubscriptionService`.
library;

import 'dart:async';

import 'package:haven/src/rust/api.dart';

/// A fake [LiveSyncFfi] engine. Only the methods the service drives are
/// overridden; everything else (the `RustOpaqueInterface` internals) routes to
/// [noSuchMethod] and is never called by the service.
class FakeLiveSyncEngine implements LiveSyncFfi {
  FakeLiveSyncEngine({
    this.failStart = false,
    this.failSubscribe = false,
    this.failUnsubscribe = false,
    this.failLiveEvents = false,
    this.failBurstOpen = false,
    this.failBacklogWait = false,
    this.failSettle = false,
    this.failPause = false,
    this.failPoolCount = false,
    this.failClaim = false,
  });

  /// When true, [claimForeground] throws (with a hex-like detail, to prove
  /// the service never leaks it — Security Rule 8).
  final bool failClaim;

  /// When set, [startSession] does not resolve until it completes: a start
  /// that is still connecting when something else happens to the service.
  Completer<void>? startGate;

  /// Whether a [stopSession] ends a [startSession] parked on [startGate], as
  /// the real engine's does: its stop raises the shutdown flag before it
  /// waits for the start, and the start fails at its next check.
  ///
  /// `false` is the stop that reached the engine before the engine had
  /// installed the session it was asked to end: it stops nothing, and the
  /// start comes up behind it.
  bool stopEndsStart = true;

  /// When set, [stopSession] does not resolve until it completes: a teardown
  /// still unwinding when something else happens to the service.
  Completer<void>? stopGate;

  /// When set, [claimForeground] does not resolve until it completes: the
  /// engine's lifecycle lock held by something else, or a claim that is
  /// publishing what an earlier pass left owed.
  Completer<void>? claimGate;

  /// Completed by a [stopSession] that ends the [startSession] in flight.
  Completer<void>? _startEnded;

  /// Every call the service made of this engine that matters to a start in
  /// flight, in the order the ENGINE saw them.
  final List<String> calls = [];

  /// The foreground claim each [resumeAfterBackground] carried, in call order.
  final List<bool> resumeClaims = [];

  /// The foreground claim each [claimForeground] carried, in call order.
  final List<bool> foregroundClaims = [];

  /// When true, [liveEvents] throws — the one failure that lands AFTER the
  /// service has taken ownership of the handle, so it distinguishes "the
  /// failure path released an abandoned engine" from "it double-released one
  /// `stop()` already owns".
  final bool failLiveEvents;

  /// Counts [dispose] calls, not just whether one happened: a double dispose is
  /// a different defect from a leak and must be visible as one.
  int disposeCalls = 0;

  /// When true, [startSession] throws (with a hex-like detail, to prove the
  /// service never leaks it — Security Rule 8).
  final bool failStart;

  /// When true, [subscribeCircle] throws — the delta-op counterpart to
  /// [failStart].
  final bool failSubscribe;

  /// When true, [unsubscribeCircle] throws — the delta-op counterpart to
  /// [failStart].
  final bool failUnsubscribe;

  /// When true, [openBackgroundBurstWithin] throws — with a hex-like detail, to
  /// prove the service never leaks it (Security Rule 8).
  final bool failBurstOpen;

  /// When true, [waitBacklogSettled] throws.
  final bool failBacklogWait;

  /// When true, [settleBeforePause] throws. Its whole job is to run to
  /// completion immediately before the pause on the same `finally` path, so a
  /// throw that escaped would skip the pause and leave the burst's sockets
  /// open until some later burst closed them.
  final bool failSettle;

  /// When true, [pauseSubscriptions] throws. The pause is the caller's
  /// `finally` link, so this models the one failure that must NOT become an
  /// exception the caller sees instead of the one that aborted its burst.
  final bool failPause;

  /// When true, [poolSubscriptionCount] throws (with a hex-like detail, to
  /// prove the service never leaks it — Security Rule 8).
  final bool failPoolCount;

  /// What [waitBacklogSettled] answers when it does not throw.
  BacklogOutcomeFfi backlogOutcome = BacklogOutcomeFfi.settled;

  /// What [poolSubscriptionCount] answers, held INDEPENDENTLY of [_paused] on
  /// purpose: the real core raises its paused flag as the first statement of
  /// the pause and drops the REQs afterwards, so the two really can disagree,
  /// and a fake that derived one from the other could not express the state an
  /// `isPaused` oracle misreports.
  int poolSubscriptions = 0;

  /// How many LEADING [stopSession] calls throw, modelling the real FFI's
  /// `StopOutcome::TimedOut` → `Err` (with the wedged core reinstalled into the
  /// process-global `SESSION`, which is what makes a retry meaningful).
  /// Set to 1 for "the retry succeeds", 2 for "it never lets go".
  int failStopCalls = 0;

  /// The [stopSession] calls that throw, by 1-based call number — for a
  /// failure that is not the first call's.
  Set<int> failStopOn = const {};

  final StreamController<FfiRelayEvent> controller =
      StreamController<FfiRelayEvent>();
  int startCalls = 0;
  int stopCalls = 0;
  int resumeCalls = 0;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  int burstOpenCalls = 0;
  int backlogWaitCalls = 0;
  int settleCalls = 0;
  int pauseCalls = 0;
  int poolCountCalls = 0;

  /// Set by [dispose]. The engine handle owns an `Arc<CircleManager>` clone, so
  /// until it is released the MLS DB's Rule-14 single-session slot stays held
  /// and the next open of the same `session.sqlite` fails closed. Nulling the
  /// field is not enough (that only makes it GC-eligible) — `stop()` must
  /// dispose it.
  bool disposed = false;

  bool _running = false;
  bool _paused = false;

  /// What [lifecycle] answers; when null, it follows [isRunning] and
  /// [isPaused].
  LiveLifecycleFfi? lifecycleAnswer;

  @override
  LiveLifecycleFfi lifecycle() =>
      lifecycleAnswer ??
      (isRunning()
          ? (isPaused() ? LiveLifecycleFfi.paused : LiveLifecycleFfi.launched)
          : LiveLifecycleFfi.stopped);

  /// The inbox relays each [startSession] was handed, in call order.
  final List<List<String>> startInboxRelays = [];

  /// The budget each [startSessionIntoBurst] was handed, in milliseconds.
  final List<BigInt> burstStartBudgets = [];

  @override
  Future<void> startSessionIntoBurst({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
    required BigInt budgetMs,
  }) async {
    burstStartBudgets.add(budgetMs);
    calls.add('startIntoBurst');
    await startSession(groups: groups, inboxRelays: inboxRelays);
  }

  @override
  Future<void> startSession({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {
    startCalls++;
    startInboxRelays.add(inboxRelays);
    calls.add('start');
    final gate = startGate;
    if (gate != null) {
      final ended = _startEnded = Completer<void>();
      await Future.any([gate.future, ended.future]);
      _startEnded = null;
      if (ended.isCompleted) {
        throw Exception('no session, group deadbeefcafef00ddeadbeefcafef00d');
      }
    }
    if (failStart) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    _running = true;
    calls.add('started');
  }

  @override
  Stream<FfiRelayEvent> liveEvents() {
    if (failLiveEvents) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    return controller.stream;
  }

  @override
  bool isRunning() => _running;

  @override
  Future<void> stopSession() async {
    // Faithful to the bridge: a call on a released handle throws.
    if (disposed) throw StateError('stopSession on a disposed handle');
    stopCalls++;
    calls.add('stop');
    final ended = _startEnded;
    if (stopEndsStart && ended != null && !ended.isCompleted) ended.complete();
    await stopGate?.future;
    if (stopCalls <= failStopCalls || failStopOn.contains(stopCalls)) {
      throw Exception('live session did not stop cleanly, group deadbeefcafe');
    }
    _running = false;
    // Faithful to the real engine: `stopSession` tears down the native event
    // bus, which is what ends the `liveEvents()` stream. Without modelling that
    // coupling the fake cannot reproduce the `onDone` a deliberate stop
    // provokes, and any test claiming to pin re-entrancy is vacuous.
    // NOT awaited: `close()` on a single-subscription controller that was
    // never listened to only completes once a subscriber drains it, so awaiting
    // here would hang whenever the service failed BEFORE subscribing. The real
    // engine does not await stream delivery either.
    if (!controller.isClosed) {
      unawaited(controller.close());
    }
  }

  // Both entry points route through the core's `resume_burst`, whose FIRST act
  // — before it adds a relay, connects, or issues a REQ — is to clear the
  // paused flag. So the flag is cleared here too, and for BOTH, and BEFORE the
  // failure: an open that fails part way really does leave an un-paused
  // session behind. A fake that cleared it only on the burst path, and only on
  // success, would teach the burst's future caller the wrong model of what it
  // is holding when its `finally` runs.
  @override
  Future<void> resumeAfterBackground({required bool foreground}) async {
    resumeCalls++;
    resumeClaims.add(foreground);
    _paused = false;
  }

  @override
  Future<void> claimForeground({required bool foreground}) async {
    foregroundClaims.add(foreground);
    calls.add('claim:$foreground');
    await claimGate?.future;
    if (failClaim) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
  }

  /// The budget each burst open was handed, in milliseconds, in call order.
  final List<BigInt> burstOpenBudgets = [];

  /// What a burst open answers when it does not throw.
  BurstOpenFfi burstOpenAnswer = BurstOpenFfi.opened;

  @override
  Future<BurstOpenFfi> openBackgroundBurstWithin({
    required BigInt budgetMs,
  }) async {
    burstOpenCalls++;
    burstOpenBudgets.add(budgetMs);
    _paused = false;
    if (failBurstOpen) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    return burstOpenAnswer;
  }

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async {
    backlogWaitCalls++;
    if (failBacklogWait) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    return backlogOutcome;
  }

  @override
  Future<void> settleBeforePause() async {
    settleCalls++;
    if (failSettle) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
  }

  // The core raises its paused flag as the FIRST statement of the pause, so it
  // is raised here before the failure too: a pause that broke half way through
  // still reports as paused, which is precisely why `isPaused` cannot be read
  // as "the radio is off".
  @override
  Future<void> pauseSubscriptions() async {
    pauseCalls++;
    calls.add('pause');
    _paused = true;
    if (failPause) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
  }

  @override
  bool isPaused() => _paused;

  @override
  Future<int> poolSubscriptionCount() async {
    poolCountCalls++;
    if (failPoolCount) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    return poolSubscriptions;
  }

  @override
  Future<void> subscribeCircle({required FfiGroupSpec spec}) async {
    subscribeCalls++;
    if (failSubscribe) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
  }

  @override
  Future<void> unsubscribeCircle({required List<int> nostrGroupId}) async {
    unsubscribeCalls++;
    if (failUnsubscribe) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
  }

  @override
  void dispose() {
    disposeCalls++;
    disposed = true;
  }

  @override
  bool get isDisposed => disposed;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}
