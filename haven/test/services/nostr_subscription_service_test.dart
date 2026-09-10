import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

/// A fake [LiveSyncFfi] engine. Only the methods the service drives are
/// overridden; everything else (the `RustOpaqueInterface` internals) routes to
/// [noSuchMethod] and is never called by the service.
class _FakeEngine implements LiveSyncFfi {
  _FakeEngine({
    this.failStart = false,
    this.failSubscribe = false,
    this.failUnsubscribe = false,
    this.failLiveEvents = false,
    this.failBurstOpen = false,
    this.failBacklogWait = false,
    this.failSettle = false,
    this.failPause = false,
    this.failPoolCount = false,
  });

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

  /// When true, [openBackgroundBurst] throws — with a hex-like detail, to
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

  @override
  Future<void> startSession({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {
    startCalls++;
    if (failStart) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
    _running = true;
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
    stopCalls++;
    if (stopCalls <= failStopCalls) {
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
  Future<void> resumeAfterBackground() async {
    resumeCalls++;
    _paused = false;
  }

  @override
  Future<void> openBackgroundBurst() async {
    burstOpenCalls++;
    _paused = false;
    if (failBurstOpen) {
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
    }
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

/// A [LiveEventRouter] subclass that records handled-event order and can block
/// on a gate, to pin FIFO serialization + the stop→start chain reset (F2).
class _SpyRouter extends LiveEventRouter {
  _SpyRouter()
    : super(
        circleService: MockCircleService(),
        circlesSnapshot: () async => const [],
        secretBytes: () async => const [],
        parseLocation: (_, _) async => null,
        ingestLocation: (_, _) async {},
        reconcileRoster: (_) async {},
        onLocationsChanged: () {},
        onGroupUpdated: (_) {},
        onInvitationReceived: () {},
        onStatus: (_) {},
      );

  final List<FfiSyncStatusReason?> seen = [];

  /// When set, [handleEvent] awaits it before returning (to hold a handler
  /// in-flight while the test drives stop()/start()).
  Completer<void>? gate;

  @override
  Future<void> handleEvent(FfiRelayEvent event) async {
    seen.add(event.statusReason);
    final g = gate;
    if (g != null) await g.future;
  }
}

FfiRelayEvent _status(FfiSyncStatusReason reason) =>
    FfiRelayEvent(kind: FfiRelayEventKind.status, statusReason: reason);

void main() {
  group('NostrSubscriptionService', () {
    test('isRunning reflects the engine session', () async {
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      expect(service.isRunning, isFalse, reason: 'no engine yet');
      await service.start(groups: const [], inboxRelays: const []);
      expect(service.isRunning, isTrue);
      await service.stop();
      expect(service.isRunning, isFalse);
    });

    test('start is idempotent — the engine is built once', () async {
      var factoryCalls = 0;
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async {
          factoryCalls++;
          return engine;
        },
      );
      await service.start(groups: const [], inboxRelays: const []);
      await service.start(groups: const [], inboxRelays: const []);
      expect(factoryCalls, 1, reason: 'second start is a no-op');
      expect(engine.startCalls, 1);
    });

    test(
      'start failure throws a generic exception and does not leak',
      () async {
        final engine = _FakeEngine(failStart: true);
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );
        Object? thrown;
        try {
          await service.start(groups: const [], inboxRelays: const []);
        } on Object catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SubscriptionServiceException>());
        // Generic message only — never the raw FFI error / its hex detail.
        expect('$thrown', isNot(contains('deadbeef')));
        expect('$thrown', contains('failed to start live session'));
        expect(service.isRunning, isFalse);
      },
    );

    test('stop cancels the stream + stops the session; idempotent', () async {
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      // stop() before any start() is a no-op (no throw).
      await service.stop();
      await service.start(groups: const [], inboxRelays: const []);
      await service.stop();
      expect(engine.stopCalls, 1);
      expect(engine.controller.hasListener, isFalse, reason: 'sub cancelled');
      await service.stop(); // second stop is a no-op
      expect(engine.stopCalls, 1);
    });

    test('stop releases the engine handle (Rule-14 session slot)', () async {
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      expect(engine.disposed, isFalse);
      await service.stop();
      // The handle owns an `Arc<CircleManager>` clone; dropping the Dart
      // reference alone defers the Rust `Drop` — and with it the release of the
      // MLS DB's Rule-14 `LiveSessionGuard` — to a GC that may never run before
      // the next open. A logout→login in one process (or a second HavenApp
      // pumped in one test process) then fails closed on "an MLS session is
      // already open on this database".
      expect(
        engine.disposed,
        isTrue,
        reason: 'stop() must dispose the engine handle, not just null it',
      );
      // Ordering: the disposal must come AFTER stopSession()/stream cancel, so
      // teardown never calls into an already-released handle.
      expect(engine.stopCalls, 1);
      expect(engine.controller.hasListener, isFalse);
    });

    test('a fresh start after stop builds a NEW engine, never the disposed '
        'one', () async {
      final engines = <_FakeEngine>[];
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async {
          final e = _FakeEngine();
          engines.add(e);
          return e;
        },
      );
      await service.start(groups: const [], inboxRelays: const []);
      await service.stop();
      await service.start(groups: const [], inboxRelays: const []);
      expect(engines, hasLength(2), reason: 'restart must re-run the factory');
      expect(engines.first.disposed, isTrue);
      expect(
        engines.last.disposed,
        isFalse,
        reason: 'the live engine must not be disposed while it is running',
      );
      expect(engines.last.startCalls, 1);
    });

    test('events are handled in FIFO order', () async {
      final engine = _FakeEngine();
      final router = _SpyRouter();
      final service = NostrSubscriptionService(
        router: router,
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      engine.controller
        ..add(_status(FfiSyncStatusReason.connecting))
        ..add(_status(FfiSyncStatusReason.connected));
      await pumpEventQueue();
      expect(router.seen, [
        FfiSyncStatusReason.connecting,
        FfiSyncStatusReason.connected,
      ]);
      await service.stop();
    });

    test(
      'stop resets the chain so a new session ignores old handlers (F2)',
      () async {
        final engine1 = _FakeEngine();
        final engine2 = _FakeEngine();
        var built = 0;
        final router = _SpyRouter();
        final service = NostrSubscriptionService(
          router: router,
          engineFactory: () async => built++ == 0 ? engine1 : engine2,
        );
        await service.start(groups: const [], inboxRelays: const []);

        // Hold session 1's handler in-flight on a gate.
        final aGate = Completer<void>();
        router.gate = aGate;
        engine1.controller.add(_status(FfiSyncStatusReason.connecting));
        await pumpEventQueue();
        expect(router.seen, [FfiSyncStatusReason.connecting]);
        expect(aGate.isCompleted, isFalse, reason: 'handler A still blocked');

        // Stop (resets _processing) and start a fresh session; its event must
        // run WITHOUT waiting on A's still-blocked handler.
        await service.stop();
        router.gate = null;
        await service.start(groups: const [], inboxRelays: const []);
        engine2.controller.add(_status(FfiSyncStatusReason.connected));
        await pumpEventQueue();

        expect(router.seen, [
          FfiSyncStatusReason.connecting,
          FfiSyncStatusReason.connected,
        ], reason: 'B ran despite A being blocked — chain was reset');
        expect(aGate.isCompleted, isFalse);

        aGate.complete(); // let A drain
        await pumpEventQueue();
        await service.stop();
      },
    );

    test(
      'subscribeCircle delegates to the engine when a session is active',
      () async {
        final engine = _FakeEngine();
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );
        await service.start(groups: const [], inboxRelays: const []);
        await service.subscribeCircle(
          FfiGroupSpec(
            nostrGroupId: Uint8List.fromList(List<int>.filled(32, 1)),
            relays: const ['wss://relay.test'],
          ),
        );
        expect(engine.subscribeCalls, 1);
        await service.stop();
      },
    );

    test(
      'subscribeCircle throws a generic exception when no session is active',
      () async {
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => _FakeEngine(),
        );
        await expectLater(
          service.subscribeCircle(
            FfiGroupSpec(
              nostrGroupId: Uint8List.fromList(List<int>.filled(32, 1)),
              relays: const [],
            ),
          ),
          throwsA(isA<SubscriptionServiceException>()),
        );
      },
    );

    test(
      'a subscribeCircle engine failure throws generically and never leaks',
      () async {
        final engine = _FakeEngine(failSubscribe: true);
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );
        await service.start(groups: const [], inboxRelays: const []);
        Object? thrown;
        try {
          await service.subscribeCircle(
            FfiGroupSpec(
              nostrGroupId: Uint8List.fromList(List<int>.filled(32, 1)),
              relays: const [],
            ),
          );
        } on Object catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SubscriptionServiceException>());
        expect('$thrown', isNot(contains('deadbeef')));
        await service.stop();
      },
    );

    test(
      'unsubscribeCircle delegates to the engine when a session is active',
      () async {
        final engine = _FakeEngine();
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );
        await service.start(groups: const [], inboxRelays: const []);
        await service.unsubscribeCircle(Uint8List.fromList(List.filled(32, 1)));
        expect(engine.unsubscribeCalls, 1);
        await service.stop();
      },
    );

    test(
      'unsubscribeCircle throws a generic exception when no session is '
      'active',
      () async {
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => _FakeEngine(),
        );
        await expectLater(
          service.unsubscribeCircle(Uint8List.fromList(List.filled(32, 1))),
          throwsA(isA<SubscriptionServiceException>()),
        );
      },
    );

    test(
      'an unsubscribeCircle engine failure throws generically and never '
      'leaks',
      () async {
        final engine = _FakeEngine(failUnsubscribe: true);
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );
        await service.start(groups: const [], inboxRelays: const []);
        Object? thrown;
        try {
          await service.unsubscribeCircle(
            Uint8List.fromList(List.filled(32, 1)),
          );
        } on Object catch (e) {
          thrown = e;
        }
        expect(thrown, isA<SubscriptionServiceException>());
        expect('$thrown', isNot(contains('deadbeef')));
        await service.stop();
      },
    );
  });

  group('a failed start does not strand the Rule-14 guard', () {
    // A `LiveSyncFfi` holds an `Arc<CircleManager>`, so an undisposed handle
    // keeps the MLS database's single-session guard registered. The native
    // finalizer runs on GC — non-deterministic, possibly never — so the failure
    // path has to release it explicitly.

    test('the engine is disposed when startSession throws', () async {
      final engine = _FakeEngine(failStart: true);
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );

      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(isA<SubscriptionServiceException>()),
      );

      expect(
        engine.disposed,
        isTrue,
        reason: 'the handle is referenced by nothing after this throw, so if '
            'it is not disposed here the guard is held until GC — the database '
            'stays unopenable and no retry can succeed',
      );
    });

    test('repeated failures do not accumulate live handles', () async {
      // The self-heal retries on a timer, so a persistent failure would
      // otherwise add one guard holder per attempt.
      final built = <_FakeEngine>[];
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async {
          final e = _FakeEngine(failStart: true);
          built.add(e);
          return e;
        },
      );

      for (var i = 0; i < 3; i++) {
        await expectLater(
          service.start(groups: const [], inboxRelays: const []),
          throwsA(isA<SubscriptionServiceException>()),
        );
      }

      expect(built, hasLength(3));
      expect(
        built.every((e) => e.disposed),
        isTrue,
        reason: 'every abandoned handle must be released, or a retry loop '
            'permanently blocks both its own next attempt and the foreground '
            "service's reclaim",
      );
    });

    test('a throw AFTER ownership transfers disposes exactly once', () async {
      // `liveEvents()` runs after `_engine` is assigned, so `stop()` in the
      // catch already owns the disposal. If the failure path also fired, the
      // handle would be disposed twice — which is why ownership is handed over
      // explicitly rather than left for both paths to guess at.
      final engine = _FakeEngine(failLiveEvents: true);
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );

      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(isA<SubscriptionServiceException>()),
      );

      expect(
        engine.disposeCalls,
        1,
        reason: 'exactly one release: neither leaked nor double-disposed',
      );
      expect(service.isRunning, isFalse);
    });

    test('a SUCCESSFUL start does not dispose the live engine', () async {
      // The failure path must not over-fire: disposing a handle that is now
      // owned by `_engine` would tear down the session it just established.
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );

      await service.start(groups: const [], inboxRelays: const []);

      expect(engine.disposed, isFalse);
      expect(service.isRunning, isTrue);
      await service.stop();
      expect(engine.disposed, isTrue, reason: 'stop still owns the disposal');
    });
  });

  group('an unexpected engine death is survivable', () {
    // The engine can stop for reasons this service does not control: a
    // Rust-side teardown, or another isolate force-releasing the process-global
    // session to reclaim the MLS database. The stream closing is the only
    // signal that reaches Dart.

    test('the stream closing returns the service to a restartable state',
        () async {
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      // The engine dies underneath us.
      await engine.controller.close();
      await pumpEventQueue();

      expect(
        engine.disposed,
        isTrue,
        reason: 'the dead handle holds an Arc<CircleManager>, so until it is '
            'disposed the Rule-14 guard stays registered and a reclaiming '
            'isolate cannot open the database',
      );
      expect(
        service.isRunning,
        isFalse,
        reason: 'the service must not keep claiming to run',
      );
    });

    test('a restart after an unexpected close builds a FRESH engine', () async {
      final first = _FakeEngine();
      final second = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => (built++ == 0) ? first : second,
      );
      await service.start(groups: const [], inboxRelays: const []);

      await first.controller.close();
      await pumpEventQueue();

      // THE property: `start` early-returns while `_engine != null`, so without
      // the teardown above this call would be a silent no-op and live receive
      // would stay dead for the rest of the process.
      await service.start(groups: const [], inboxRelays: const []);

      expect(built, 2, reason: 'a second engine must actually be built');
      expect(second.startCalls, 1);
      expect(service.isRunning, isTrue);
      await service.stop();
    });

    test('a deliberate stop is not mistaken for a death', () async {
      // `stop()` closes the bus itself, so it necessarily triggers the same
      // `onDone`. If that were treated as an unexpected close it would call
      // `stop()` again from inside its own teardown.
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      await service.stop();
      await engine.controller.close();
      await pumpEventQueue();

      expect(
        engine.stopCalls,
        1,
        reason: 'a re-entrant teardown would stop the session twice',
      );
    });
  });

  group('a stop that did not drain is retried and reported', () {
    // The C1 wedge. A `StopOutcome::TimedOut` reinstalls the wedged core into
    // the Rust-global `SESSION` and returns `Err`. Swallowing that error and
    // carrying on hands the guard to a static no Dart handle in any isolate
    // references: the foreground service cannot open (held), its reclaim
    // declines (this isolate is provably alive), and the app is dead until a
    // Force Stop. The retry is the only lever, and it is only reachable from
    // here — once this method returns nothing holds that core.

    test('a first failure is retried and the second attempt succeeds',
        () async {
      final engine = _FakeEngine()..failStopCalls = 1;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      final outcome = await service.stop();

      expect(
        engine.stopCalls,
        2,
        reason: 'the reinstalled core is re-joined by a second stopSession; '
            'giving up after one leaves the guard held forever',
      );
      expect(outcome, LiveSyncStopOutcome.stopped);
      expect(engine.disposed, isTrue);
    });

    test('a stop that never drains reports stillHolding, not success',
        () async {
      final engine = _FakeEngine()..failStopCalls = 2;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      final outcome = await service.stop();

      expect(engine.stopCalls, 2, reason: 'exactly one retry, not a loop');
      expect(
        outcome,
        LiveSyncStopOutcome.stillHolding,
        reason: 'the caller decides whether to dispose its own manager on '
            'this answer; reporting success would make it dispose the last '
            'Dart reference to a guard the engine still holds',
      );
    });

    test('a clean stop reports stopped and an absent engine reports idle',
        () async {
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );

      expect(
        await service.stop(),
        LiveSyncStopOutcome.idle,
        reason: 'nothing was running, so nothing was holding anything',
      );

      await service.start(groups: const [], inboxRelays: const []);
      expect(await service.stop(), LiveSyncStopOutcome.stopped);
      expect(engine.stopCalls, 1, reason: 'a clean stop is never retried');
    });

    test('a SECOND stop still reports the guard the first one left held',
        () async {
      // [stop] clears `_engine` before it returns, so the next stop finds
      // nothing to stop. Answering `idle` there — "nothing was holding
      // anything" — while the wedged core Rust reinstalled into `SESSION` still
      // owns the guard would hand the pause path a green light one pause later,
      // and it would dispose the last Dart reference to a held guard: C1,
      // reached the long way round.
      final engine = _FakeEngine()..failStopCalls = 2;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);
      expect(
        await service.stop(),
        LiveSyncStopOutcome.stillHolding,
        reason: 'the state is a property of the process-global session, not '
            'of whether this object still has a handle to it',
      );
    });

    test('a successful start discharges the still-holding latch', () async {
      // The complement, and the only event that PROVES the wedge is gone: Rust
      // refuses to install a second session over a live one, so a session that
      // started means the previous core drained. Without this the service
      // would report `stillHolding` forever and the pause path would never
      // hand over again.
      var built = 0;
      final wedged = _FakeEngine()..failStopCalls = 2;
      final fresh = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? wedged : fresh,
      );

      await service.start(groups: const [], inboxRelays: const []);
      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);

      await service.start(groups: const [], inboxRelays: const []);
      expect(await service.stop(), LiveSyncStopOutcome.stopped);
      expect(
        await service.stop(),
        LiveSyncStopOutcome.idle,
        reason: 'with the latch discharged, an absent engine is genuinely '
            'nothing to stop',
      );
    });

    test('a FAILED start does not discharge the latch', () async {
      // The fail-closed half, and the one a plain "clear it at the top of
      // start()" would get wrong. Rust's `start_session` takes the wedged core
      // out of `SESSION`, tries to stop it again, and on a second timeout
      // reinstalls it and refuses ("previous live session did not stop;
      // refusing to start a second") — so a start that THREW is evidence the
      // guard is still held, not evidence it was freed. Discharging the latch
      // before that call resolves would answer `idle` on the next stop and
      // hand the pause path a green light to dispose the last Dart reference
      // to a held guard.
      var built = 0;
      final wedged = _FakeEngine()..failStopCalls = 2;
      final refused = _FakeEngine(failStart: true);
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? wedged : refused,
      );

      await service.start(groups: const [], inboxRelays: const []);
      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);

      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(isA<SubscriptionServiceException>()),
      );

      expect(
        await service.stop(),
        LiveSyncStopOutcome.stillHolding,
        reason: 'the start that would have proven the wedge gone did not '
            'happen, so the latch must survive it',
      );
    });

    test('a throwing outcome observer cannot break the teardown', () async {
      // The callback is somebody else's code (Unit D wires it to the UI). A
      // throw from it must not escape a method reached from
      // `unawaited(stop())`, where nothing can catch it — and must not lose
      // the answer the caller is about to act on.
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
        onStopOutcome: (_) => throw StateError('observer blew up'),
      );
      await service.start(groups: const [], inboxRelays: const []);

      expect(await service.stop(), LiveSyncStopOutcome.stopped);
      expect(
        engine.disposed,
        isTrue,
        reason: 'the release must already have happened — the observer runs '
            'after it, precisely so it cannot prevent it',
      );
    });

    test('the outcome reaches the callback on stops nobody awaits', () async {
      // `_onStreamClosed` fires `unawaited(stop())`, and the failed-start path
      // stops from inside its own catch. Neither has a caller to read the
      // return value, and a guard left held there is exactly as serious.
      final seen = <LiveSyncStopOutcome>[];
      final engine = _FakeEngine()..failStopCalls = 2;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
        onStopOutcome: seen.add,
      );
      await service.start(groups: const [], inboxRelays: const []);

      // The engine dies underneath us — teardown runs unawaited.
      await engine.controller.close();
      await pumpEventQueue();

      expect(seen, [LiveSyncStopOutcome.stillHolding]);
    });
  });

  group('the background-burst API', () {
    Future<(NostrSubscriptionService, _FakeEngine)> started([
      _FakeEngine? engine,
    ]) async {
      final e = engine ?? _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => e,
      );
      await service.start(groups: const [], inboxRelays: const []);
      addTearDown(service.stop);
      return (service, e);
    }

    test('a burst opens through the BURST entry point, not the foreground one',
        () async {
      // The two Rust entry points exist because only the burst may consume a
      // position in the inbox fold. Routing a burst through
      // `resumeAfterBackground` compiles, runs, and silently leaves the fold
      // never applied — so the distinction is only real if it is pinned here.
      final (service, engine) = await started();

      await service.openBackgroundBurst();

      expect(engine.burstOpenCalls, 1);
      expect(
        engine.resumeCalls,
        0,
        reason: 'the burst must never take the foreground re-anchor',
      );
    });

    test('the foreground re-anchor never advances the burst counter',
        () async {
      // The other half of the same promise: an app resume and the health
      // tick's whole-session repair must not consume a fold position, or an
      // active user could go a whole fold period without an inbox REQ.
      final (service, engine) = await started();

      await service.resumeAfterBackground();

      expect(engine.resumeCalls, 1);
      expect(engine.burstOpenCalls, 0);
    });

    test('a failed burst open throws, and carries none of the FFI detail',
        () async {
      // Unlike the foreground re-anchor (retried by the health tick and the
      // next resume), a burst open has no redundancy: a caller that swallowed
      // it would then wait out the whole backlog budget on a burst that never
      // subscribed.
      final (service, engine) = await started(
        _FakeEngine(failBurstOpen: true),
      );

      await expectLater(
        service.openBackgroundBurst,
        throwsA(
          isA<SubscriptionServiceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('deadbeef')),
          ),
        ),
      );
      expect(engine.burstOpenCalls, 1);
    });

    test('opening a burst with no session throws rather than reporting one',
        () async {
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );

      await expectLater(
        service.openBackgroundBurst,
        throwsA(isA<SubscriptionServiceException>()),
      );
    });

    test('the backlog outcome is reported as the engine gave it', () async {
      final (service, engine) = await started();

      expect(await service.waitBacklogSettled(), BacklogOutcomeFfi.settled);

      engine.backlogOutcome = BacklogOutcomeFfi.timedOut;
      expect(await service.waitBacklogSettled(), BacklogOutcomeFfi.timedOut);
      expect(engine.backlogWaitCalls, 2);
    });

    test('a failed or session-less backlog wait answers timedOut', () async {
      // `settled` is a claim that every endpoint replayed. Answering it when
      // nothing was even asked would have the caller encrypt at an epoch a
      // peer commit may already have moved — `timedOut` promises nothing,
      // which is the only honest answer here.
      final (failing, _) = await started(_FakeEngine(failBacklogWait: true));
      expect(await failing.waitBacklogSettled(), BacklogOutcomeFfi.timedOut);

      final sessionless = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );
      expect(
        await sessionless.waitBacklogSettled(),
        BacklogOutcomeFfi.timedOut,
      );
    });

    test('settle and pause reach the engine', () async {
      final (service, engine) = await started();

      await service.settleBeforePause();
      await service.pauseSubscriptions();

      expect(engine.settleCalls, 1);
      expect(engine.pauseCalls, 1);
    });

    test('a failing settle never throws — the pause behind it must still run',
        () async {
      // These are consecutive links on ONE `finally` path. A throw escaping
      // the settle would skip the pause, so the burst's standing REQs and its
      // sockets would stay open for the whole gap to the next burst — the
      // always-on background socket, restored by an error path.
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      final (service, engine) = await started(_FakeEngine(failSettle: true));

      await expectLater(service.settleBeforePause(), completes);

      expect(
        engine.settleCalls,
        1,
        reason: 'anti-vacuity: it was called, and it threw',
      );
      final joined = logs.join('\n');
      expect(joined, contains('settle failed'));
      expect(
        joined,
        isNot(contains('deadbeef')),
        reason: 'the FFI detail is remote text (Security Rule 8)',
      );
    });

    test("a failing pause never throws — it is the caller's finally link",
        () async {
      // A throw here would REPLACE whatever failure aborted the burst with a
      // less informative one, and the caller would lose the error it was
      // handling.
      final (service, engine) = await started(_FakeEngine(failPause: true));

      await expectLater(service.pauseSubscriptions(), completes);
      expect(engine.pauseCalls, 1);
    });

    test('settle and pause with no session are no-ops', () async {
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );

      await expectLater(service.settleBeforePause(), completes);
      await expectLater(service.pauseSubscriptions(), completes);
    });

    test('isPaused tracks the engine and is orthogonal to isRunning',
        () async {
      final (service, _) = await started();
      expect(service.isPaused, isFalse);

      await service.pauseSubscriptions();
      expect(service.isPaused, isTrue);
      expect(
        service.isRunning,
        isTrue,
        reason: 'a paused session is alive — it simply holds no REQ; a caller '
            'that read isRunning as "not paused" would re-anchor it and '
            'silently re-open standing REQs in the background',
      );

      await service.openBackgroundBurst();
      expect(service.isPaused, isFalse);
    });

    test('the FOREGROUND re-anchor un-pauses the session too', () async {
      // Both entry points reach the core's one `resume_burst`, and clearing
      // the paused flag is its first act. A caller that treated
      // `resumeAfterBackground` as pause-preserving — an app resume arriving
      // mid-pause, say — would go on believing the engine holds no socket
      // while it holds all of them.
      final (service, _) = await started();

      await service.pauseSubscriptions();
      expect(service.isPaused, isTrue);

      await service.resumeAfterBackground();
      expect(service.isPaused, isFalse);
    });

    test('a failed burst open leaves the session UN-paused', () async {
      // The flag is cleared before the open touches a socket, so a failure
      // part way through does not restore it. This is why the caller's
      // `finally` must pause even when the open threw: there is no "left as it
      // was" state to fall back on.
      final (service, _) = await started();

      await service.pauseSubscriptions();
      expect(service.isPaused, isTrue);

      final failing = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(failBurstOpen: true),
      );
      await failing.start(groups: const [], inboxRelays: const []);
      addTearDown(failing.stop);
      await failing.pauseSubscriptions();
      expect(failing.isPaused, isTrue);

      await expectLater(
        failing.openBackgroundBurst,
        throwsA(isA<SubscriptionServiceException>()),
      );
      expect(failing.isPaused, isFalse);
    });

    test('the pool count reports the REQs, where isPaused reports the intent',
        () async {
      // The two observables the background-burst promise can be read from, and
      // the whole reason the count exists: the core raises `paused` as the
      // FIRST statement of its pause and drops the REQs after it, so there is
      // a real state — pause entered, subscriptions still registered — in which
      // an `isPaused` oracle answers "nothing is standing" while something is.
      final (service, engine) = await started();
      engine.poolSubscriptions = 3;

      expect(service.isPaused, isFalse);
      expect(await service.poolSubscriptionCount(), 3);

      await service.pauseSubscriptions();

      expect(service.isPaused, isTrue, reason: 'the intent flag is up');
      expect(
        await service.poolSubscriptionCount(),
        3,
        reason: 'and the REQs are still registered — an oracle built on the '
            'flag would already be reporting the promise kept',
      );

      engine.poolSubscriptions = 0;
      expect(await service.poolSubscriptionCount(), isZero);
    });

    test('a count with no session THROWS rather than answering zero', () async {
      // Zero is the PASSING value of "no standing REQ between bursts", so a
      // session-less read that answered it would let an engine that never
      // started prove the promise.
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );

      await expectLater(
        service.poolSubscriptionCount,
        throwsA(isA<SubscriptionServiceException>()),
      );
    });

    test('a failed count read throws and carries none of the FFI detail',
        () async {
      final (service, engine) = await started(_FakeEngine(failPoolCount: true));

      await expectLater(
        service.poolSubscriptionCount,
        throwsA(
          isA<SubscriptionServiceException>().having(
            (e) => e.message,
            'message',
            isNot(contains('deadbeef')),
          ),
        ),
      );
      expect(engine.poolCountCalls, 1);
    });

    test('isPaused reads false with no engine, and logs a failed FFI read',
        () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );
      expect(service.isPaused, isFalse, reason: 'no engine yet');
      expect(logs, isEmpty, reason: 'no engine is not a failure');

      final live = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _ThrowingPausedEngine(),
      );
      await live.start(groups: const [], inboxRelays: const []);
      addTearDown(live.stop);

      expect(
        live.isPaused,
        isFalse,
        reason: 'fail safe: a caller that reads "not paused" re-anchors, '
            'which is the recoverable direction',
      );
      // `false` is also what a genuinely un-paused engine answers, so a read
      // that failed has to be visible somewhere or it is silent.
      final joined = logs.join('\n');
      expect(joined, contains('isPaused read failed'));
      expect(
        joined,
        isNot(contains('deadbeef')),
        reason: 'the thrown message embeds a fake group id; only the type may '
            'ever be logged (Security Rule 8)',
      );
    });
  });
}

/// A [_FakeEngine] whose [isPaused] read itself throws — the FFI boundary
/// failing rather than the session answering. The message embeds a fake group
/// id, which the test above captures the logs to prove is never printed.
class _ThrowingPausedEngine extends _FakeEngine {
  @override
  bool isPaused() =>
      throw Exception('boom for mls group deadbeefcafef00ddeadbeefcafef00d');
}
