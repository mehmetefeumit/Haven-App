import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart'
    show kLiveSyncRestartBudget;
import 'package:haven/src/services/mls_session_handover.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../helpers/fake_live_sync_engine.dart';
import '../helpers/log_capture.dart';
import '../mocks/mock_circle_service.dart';

/// The shared fake engine, under the name this file has always used for it.
typedef _FakeEngine = FakeLiveSyncEngine;

/// A [LiveEventRouter] subclass that records handled-event order and can block
/// on a gate, to pin FIFO serialization + the stop→start chain reset (F2).
class _SpyRouter extends LiveEventRouter {
  _SpyRouter()
    : super(
        circleService: MockCircleService.new,
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
  Future<void> handleEvent(
    FfiRelayEvent event, {
    bool Function()? identityEnded,
  }) async {
    seen.add(event.statusReason);
    final g = gate;
    if (g != null) await g.future;
  }
}

/// A real [LiveEventRouter] whose location parse waits for [parsing], and
/// which records what it ingests.
LiveEventRouter _locationRouter(
  List<DecryptedLocation> ingested, {
  required Completer<void> parsing,
}) => LiveEventRouter(
  circleService: MockCircleService.new,
  circlesSnapshot: () async => [
    Circle(
      mlsGroupId: const [9, 9, 9],
      nostrGroupId: const [1, 2, 3],
      displayName: 'Test',
      circleType: CircleType.locationSharing,
      relays: const ['wss://relay.test'],
      membershipStatus: MembershipStatus.accepted,
      members: const [],
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ],
  secretBytes: () async => const [],
  parseLocation: (_, sender) async {
    await parsing.future;
    return DecryptedLocation(
      senderPubkey: sender,
      latitude: 1,
      longitude: 2,
      geohash: 'g',
      timestamp: DateTime(2026),
      expiresAt: DateTime(2026, 1, 2),
    );
  },
  ingestLocation: (_, decrypted) async => ingested.add(decrypted),
  reconcileRoster: (_) async {},
  onLocationsChanged: () {},
  onGroupUpdated: (_) {},
  onInvitationReceived: () {},
  onStatus: (_) {},
);

FfiRelayEvent _location(String sender) => FfiRelayEvent(
  kind: FfiRelayEventKind.location,
  nostrGroupId: Uint8List.fromList(const [1, 2, 3]),
  senderPubkey: sender,
  content: '{}',
);

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

    test(
      'a start failure never logs the raw error text, even in debug builds '
      '(Rule 8/15)',
      () async {
        final logged = LogCapture.install();
        final engine = _FakeEngine(failStart: true);
        final service = NostrSubscriptionService(
          router: _SpyRouter(),
          engineFactory: () async => engine,
        );

        await expectLater(
          service.start(groups: const [], inboxRelays: const []),
          throwsA(isA<SubscriptionServiceException>()),
        );

        logged.assertContains('Exception');
        logged.assertNoNeedles(['deadbeefcafef00ddeadbeefcafef00d']);
      },
    );

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
      // A start that succeeded is reported first: it proves the previous
      // session drained.
      expect(seen, [LiveSyncStopOutcome.stopped]);
      seen.clear();

      // The engine dies underneath us — teardown runs unawaited.
      await engine.controller.close();
      await pumpEventQueue();

      expect(seen, [LiveSyncStopOutcome.stillHolding]);
    });
  });

  group('a start that succeeds', () {
    test('reports the previous session drained, through the stop callback',
        () async {
      // The sharing-health model clears a held session on this report; a
      // start is the proof, since Rust refuses a second session over a live
      // one.
      final seen = <LiveSyncStopOutcome>[];
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
        onStopOutcome: seen.add,
      );
      await service.start(groups: const [], inboxRelays: const []);
      expect(seen, [LiveSyncStopOutcome.stopped]);
    });
  });

  group('who ended a start', () {
    // The heal backs off from a start the engine's own death ended, and not
    // from one a caller's stop ended (a pause, a logout): the two must be
    // told apart by type, never by message.
    test("the engine's stream closing under the claim ends it as the "
        "engine's death", () async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final engine = _FakeEngine()..claimGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      addTearDown(service.stop);

      final start = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      await engine.controller.close();
      await pumpEventQueue();
      engine.claimGate!.complete();

      await expectLater(
        start,
        throwsA(
          isA<SubscriptionStartEnded>().having(
            (e) => e.endedByEngine,
            'endedByEngine',
            isTrue,
          ),
        ),
      );
    });

    test("a caller's stop already in flight when the start began ends it as "
        'asked for', () async {
      // Before: the stop was counted as asked before the start, so the start
      // it ended read as the engine's death and the heal backed off.
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      engine.stopGate = Completer<void>();
      final stopping = service.stop();

      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(
          isA<SubscriptionStartEnded>().having(
            (e) => e.endedByEngine,
            'endedByEngine',
            isFalse,
          ),
        ),
      );
      engine.stopGate!.complete();
      await stopping;
    });

    test("a caller's stop during the claim ends it as asked for", () async {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final engine = _FakeEngine()..claimGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );

      final start = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      final stopping = service.stop();
      engine.claimGate!.complete();

      await expectLater(
        start,
        throwsA(
          isA<SubscriptionStartEnded>().having(
            (e) => e.endedByEngine,
            'endedByEngine',
            isFalse,
          ),
        ),
      );
      await stopping;
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

    test('a burst open hands the engine its budget', () async {
      final (service, engine) = await started();

      await service.openBackgroundBurstWithin(const Duration(seconds: 42));

      expect(engine.burstOpenBudgets, [BigInt.from(42000)]);
    });

    test('a start into a burst starts the session into the burst with its '
        'budget, and claims no foreground even with the app in front',
        () async {
      // A session started into a burst is the burst's to pause; a claim would
      // make it the foreground's, which records and drives commits.
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      addTearDown(service.stop);

      await service.startIntoBurst(
        groups: const [],
        inboxRelays: const ['wss://inbox.example'],
        budget: const Duration(seconds: 7),
      );

      expect(engine.calls, contains('startIntoBurst'));
      expect(engine.burstStartBudgets, [BigInt.from(7000)]);
      expect(engine.startInboxRelays, [
        ['wss://inbox.example'],
      ]);
      expect(engine.foregroundClaims, isEmpty);
      expect(service.isRunning, isTrue);
    });

    test('a burst opens through the BURST entry point, not the foreground one',
        () async {
      // The two Rust entry points exist because only the burst may consume a
      // position in the inbox fold. Routing a burst through
      // `resumeAfterBackground` compiles, runs, and silently leaves the fold
      // never applied — so the distinction is only real if it is pinned here.
      final (service, engine) = await started();

      await service.openBackgroundBurstWithin(const Duration(seconds: 30));

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
        () => service.openBackgroundBurstWithin(const Duration(seconds: 30)),
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

    test('opening a burst with no session answers no session, typed, never '
        'opened', () async {
      // Before (X14): it threw, and the burst counted a failed open. The
      // no-session answer is typed now, so a burst starts one into itself.
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );

      expect(
        await service.openBackgroundBurstWithin(const Duration(seconds: 30)),
        BurstOpenFfi.noSession,
      );
    });

    test('an engine whose session stopped hands its no-session on, typed',
        () async {
      final (service, engine) = await started();
      engine.burstOpenAnswer = BurstOpenFfi.noSession;

      expect(
        await service.openBackgroundBurstWithin(const Duration(seconds: 30)),
        BurstOpenFfi.noSession,
      );
      engine.burstOpenAnswer = BurstOpenFfi.opened;
      expect(
        await service.openBackgroundBurstWithin(const Duration(seconds: 30)),
        BurstOpenFfi.opened,
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
      final logs = LogCapture.install();

      final (service, engine) = await started(_FakeEngine(failSettle: true));

      await expectLater(service.settleBeforePause(), completes);

      expect(
        engine.settleCalls,
        1,
        reason: 'anti-vacuity: it was called, and it threw',
      );
      final joined = logs.joined;
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

      await service.openBackgroundBurstWithin(const Duration(seconds: 30));
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
        () => failing.openBackgroundBurstWithin(const Duration(seconds: 30)),
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
      final logs = LogCapture.install();

      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(),
      );
      expect(service.isPaused, isFalse, reason: 'no engine yet');
      expect(logs.lines, isEmpty, reason: 'no engine is not a failure');

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
      final joined = logs.joined;
      expect(joined, contains('isPaused read failed'));
      expect(
        joined,
        isNot(contains('deadbeef')),
        reason: 'the thrown message embeds a fake group id; only the type may '
            'ever be logged (Security Rule 8)',
      );
    });
  });

  // The engine cannot see the screen. Every call that can put its session in
  // the foreground lifecycle — where it records commits as durable fanouts,
  // drives the stored ones and redeems a parked eviction — carries the app's
  // word for it, and that word is the STRICT read: `resumed`, and nothing
  // else. A "yes" for an unset lifecycle is how a process launched in the
  // background, with nobody looking, would be treated as the foreground.
  group('the foreground claim handed to the engine', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    // Left as a foregrounded app for whatever runs next in this isolate.
    tearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );

    /// Puts the binding in [state]; `null` is the state before the first
    /// lifecycle event has arrived.
    void enter(AppLifecycleState? state) {
      binding.resetInternalState();
      if (state != null) binding.handleAppLifecycleStateChanged(state);
      expect(binding.lifecycleState, state, reason: 'premise');
    }

    /// Runs one start, one foreground re-anchor and one heal's claim through
    /// the REAL predicate, and returns what the engine was handed: the claim
    /// of the re-anchor, and each claim it was asked to take.
    Future<List<List<bool>>> claimsMadeIn(AppLifecycleState? state) async {
      enter(state);
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      await service.resumeAfterBackground();
      await service.claimForeground();
      expect(engine.resumeCalls, 1, reason: 'the re-anchor reached the engine');
      // Back to a state that schedules frames before the stream is torn down.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.stop();
      return [engine.resumeClaims, engine.foregroundClaims];
    }

    test('a resumed app claims the foreground at every call site', () async {
      expect(await claimsMadeIn(AppLifecycleState.resumed), [
        [true],
        // Once by the start itself, the moment it held the engine, and once
        // by the claim the test made.
        [true, true],
      ]);
    });

    for (final state in <AppLifecycleState?>[
      null,
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      test('${state?.name ?? 'an unset lifecycle'} claims nothing at any call '
          'site', () async {
        expect(
          await claimsMadeIn(state),
          [
            [false],
            <bool>[],
          ],
          reason: 'only `resumed` is the foreground: anything else handed to '
              'the engine as a claim lets a process nobody is looking at '
              'record and drive commits — and a claim that is not made is '
              'not asked of the engine at all',
        );
      });
    }

    test('the claim is read at each call, never remembered', () async {
      // A session started while the app was not yet resumed must be able to
      // claim later, and one started resumed must stop claiming once the app
      // has left the foreground.
      enter(AppLifecycleState.inactive);
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      expect(engine.foregroundClaims, isEmpty, reason: 'started, not claimed');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.claimForeground();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await service.claimForeground();
      await service.resumeAfterBackground();

      expect(engine.foregroundClaims, [true]);
      expect(engine.resumeClaims, [false]);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.stop();
    });

    test('with no session there is nothing to claim for', () async {
      enter(AppLifecycleState.resumed);
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.claimForeground();
      expect(engine.foregroundClaims, isEmpty);
    });

    group('settling the claim before a change the user asked for', () {
      NostrSubscriptionService serviceOver(_FakeEngine engine) =>
          NostrSubscriptionService(
            router: _SpyRouter(),
            engineFactory: () async => engine,
          );

      test('waits for the start in flight, then claims', () async {
        enter(AppLifecycleState.resumed);
        final engine = _FakeEngine()..startGate = Completer<void>();
        final service = serviceOver(engine);
        final starting = service.start(groups: const [], inboxRelays: const []);
        addTearDown(service.stop);
        var settled = false;
        final settle = service.settleForegroundClaim().then((_) {
          settled = true;
        });
        await pumpEventQueue();
        expect(settled, isFalse, reason: 'the start has not come up');
        expect(engine.foregroundClaims, isEmpty);

        engine.startGate!.complete();
        await starting;
        await settle;

        expect(settled, isTrue);
        // The start's own claim, then the settle's: the session is claimed
        // when the settle returns, whichever of them found it first.
        expect(engine.foregroundClaims, [true, true]);
      });

      test('claims a session that was started before the app was resumed',
          () async {
        enter(AppLifecycleState.inactive);
        final engine = _FakeEngine();
        final service = serviceOver(engine);
        await service.start(groups: const [], inboxRelays: const []);
        addTearDown(service.stop);
        expect(engine.foregroundClaims, isEmpty, reason: 'premise');

        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await service.settleForegroundClaim();

        expect(engine.foregroundClaims, [true]);
      });

      test('asks nothing and waits for nothing while the app is not resumed',
          () async {
        enter(AppLifecycleState.paused);
        final engine = _FakeEngine()..startGate = Completer<void>();
        final service = serviceOver(engine);
        final starting = service.start(groups: const [], inboxRelays: const []);
        addTearDown(() async {
          engine.startGate!.complete();
          await starting;
          await service.stop();
        });

        await service.settleForegroundClaim();

        expect(engine.foregroundClaims, isEmpty);
      });

      test('with no session it returns and claims nothing', () async {
        enter(AppLifecycleState.resumed);
        final engine = _FakeEngine();
        await serviceOver(engine).settleForegroundClaim();
        expect(engine.foregroundClaims, isEmpty);
      });

      test('a start that failed does not fail the settle', () async {
        enter(AppLifecycleState.resumed);
        final engine = _FakeEngine(failStart: true);
        final service = serviceOver(engine);
        final starting = service.start(groups: const [], inboxRelays: const []);
        final ended = expectLater(
          starting,
          throwsA(isA<SubscriptionServiceException>()),
        );
        await service.settleForegroundClaim();
        await ended;
        expect(engine.foregroundClaims, isEmpty);
      });

      test('a claim the engine refuses does not fail the settle', () async {
        enter(AppLifecycleState.resumed);
        final engine = _FakeEngine(failClaim: true);
        final service = serviceOver(engine);
        await service.start(groups: const [], inboxRelays: const []);
        addTearDown(service.stop);

        await service.settleForegroundClaim();

        expect(engine.foregroundClaims, [true, true]);
      });

      test('gives up when the engine never answers the claim', () {
        enter(AppLifecycleState.resumed);
        fakeAsync((async) {
          final engine = _FakeEngine();
          final service = serviceOver(engine)
            ..start(groups: const [], inboxRelays: const []);
          async.flushMicrotasks();
          engine.claimGate = Completer<void>();
          var settled = false;
          service.settleForegroundClaim().then((_) => settled = true);
          async.flushMicrotasks();
          expect(settled, isFalse, reason: 'the claim is still out');

          async.elapse(kLiveSyncRestartBudget);

          expect(settled, isTrue);
        });
      });
    });

    test('a claim the engine refuses never throws and never leaks', () async {
      enter(AppLifecycleState.resumed);
      final logs = LogCapture.install();
      final engine = _FakeEngine(failClaim: true);
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      // The start's own claim is refused too, and the start still stands.
      await service.start(groups: const [], inboxRelays: const []);
      addTearDown(service.stop);
      expect(service.isRunning, isTrue);

      await service.claimForeground();

      expect(engine.foregroundClaims, [true, true]);
      final joined = logs.joined;
      expect(joined, contains('foreground claim failed'));
      expect(
        joined,
        isNot(contains('deadbeef')),
        reason: 'the thrown message embeds a fake group id; only the type may '
            'ever be logged (Security Rule 8)',
      );
    });

    // A start takes seconds: it connects, drains and subscribes before it
    // resolves, and the service holds no engine until it has. Everything
    // below is about what happens to the app in the meantime.

    test('a start claims with the lifecycle it finds when it holds the '
        'engine, not the one it was asked in', () async {
      enter(AppLifecycleState.resumed);
      final engine = _FakeEngine()..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      expect(engine.calls, ['start'], reason: 'premise: still in flight');

      // The user leaves while the session is still coming up.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausing = service.pauseSubscriptions();
      await pumpEventQueue();
      expect(
        engine.pauseCalls,
        0,
        reason: 'premise: there is no engine to pause yet',
      );
      engine.startGate!.complete();
      await starting;
      await pausing;

      expect(
        engine.foregroundClaims,
        isEmpty,
        reason: 'the app was resumed when the start was ASKED and paused when '
            'it finished: a claim read at the call would have put a '
            'backgrounded process in the foreground lifecycle',
      );
      expect(
        engine.pauseCalls,
        1,
        reason: 'a pause issued during a start never reached the engine: the '
            'session is up, un-paused, behind a pause that believes it ended '
            'it',
      );
      expect(engine.calls, ['start', 'started', 'pause']);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.stop();
    });

    test('a pause issued during a start that fails does nothing and does '
        'not throw', () async {
      enter(AppLifecycleState.paused);
      final engine = _FakeEngine(failStart: true)
        ..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      final pausing = service.pauseSubscriptions();
      engine.startGate!.complete();

      await expectLater(starting, throwsA(isA<SubscriptionServiceException>()));
      await pausing;
      expect(engine.pauseCalls, 0, reason: 'there was no engine to pause');
      expect(engine.disposeCalls, 1);
      expect(service.isRunning, isFalse);
    });

    test('a pause issued while the claim is parked waits for it, then pauses '
        'the session', () async {
      enter(AppLifecycleState.resumed);
      final engine = _FakeEngine()..claimGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      expect(
        engine.calls,
        ['start', 'started', 'claim:true'],
        reason: 'premise: the session is up and its claim is with the engine',
      );

      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final pausing = service.pauseSubscriptions();
      await pumpEventQueue();
      expect(
        engine.pauseCalls,
        0,
        reason: 'the engine cannot be made to drop a claim it is serving: a '
            'pause waits for the start, claim included',
      );

      engine.claimGate!.complete();
      await starting;
      await pausing;
      expect(engine.calls, ['start', 'started', 'claim:true', 'pause']);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await service.stop();
    });

    test('startSession is handed exactly the inbox relays start was given, '
        'also by a start that waited for an ended one', () async {
      enter(AppLifecycleState.resumed);
      const inbox = ['wss://inbox-a.test', 'wss://inbox-b.test'];
      final first = _FakeEngine()..claimGate = Completer<void>();
      final second = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? first : second,
      );
      final starting = service.start(groups: const [], inboxRelays: inbox);
      await pumpEventQueue();
      await service.stop();
      final waited = service.start(groups: const [], inboxRelays: inbox);
      final ended = expectLater(
        starting,
        throwsA(isA<SubscriptionStartEnded>()),
      );
      first.claimGate!.complete();
      await ended;
      await waited;

      expect(first.startInboxRelays, [inbox]);
      expect(second.startInboxRelays, [inbox]);
      await service.stop();
    });

    test('a start parked on an ended start does not come up behind a later '
        'stop', () async {
      // A full restart's start parks on a heal's start a stop ended; a pause's
      // stop then returns at once (no engine). The parked start must not
      // bring a session up in the paused process.
      enter(AppLifecycleState.resumed);
      final first = _FakeEngine()..claimGate = Completer<void>();
      final second = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? first : second,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      await service.stop();
      final parked = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      await service.stop();

      final outcomes = [
        expectLater(starting, throwsA(isA<SubscriptionStartEnded>())),
        expectLater(parked, throwsA(isA<SubscriptionStartEnded>())),
      ];
      first.claimGate!.complete();
      await Future.wait(outcomes);
      expect(
        second.startCalls,
        0,
        reason: 'a session came up behind the stop that followed its ask',
      );
      expect(service.isRunning, isFalse);
    });

    test('a start asked for after a stop that ended the start in its claim '
        'brings its own session up', () async {
      // The stop returns while the ended start is still in its claim; a start
      // asked for after it used to join that start and inherit its end.
      enter(AppLifecycleState.resumed);
      final first = _FakeEngine()..claimGate = Completer<void>();
      final second = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? first : second,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      expect(
        first.calls,
        ['start', 'started', 'claim:true'],
        reason: 'premise: the first start is in its claim',
      );
      expect(await service.stop(), LiveSyncStopOutcome.stopped);

      final asked = service.start(groups: const [], inboxRelays: const []);
      first.claimGate!.complete();
      await expectLater(starting, throwsA(isA<SubscriptionStartEnded>()));
      await asked;

      expect(
        second.startCalls,
        1,
        reason: 'the start asked for after the stop brought nothing up',
      );
      expect(service.isRunning, isTrue);
      await service.stop();
    });
  });

  // A start takes seconds and nothing bounds a caller's wait on one: the
  // pause-time handoff, the sharing-off stop, a detach and a logout all stop
  // the engine with no deadline of their own. So a stop ENDS the start it
  // finds, and a start never brings an engine up across a stop.
  group('a stop ends the start it finds', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    setUp(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );

    test("the engine's stop is issued while the start is still out, once",
        () async {
      final logs = LogCapture.install();
      final seen = <LiveSyncStopOutcome>[];
      final engine = _FakeEngine()..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
        onStopOutcome: seen.add,
      );
      Object? startError;
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .catchError((Object e) => startError = e);
      await pumpEventQueue();
      expect(engine.calls, ['start'], reason: 'premise: still in flight');

      // The gate is never opened: nothing but the stop can end this start.
      final stopping = service.stop();
      await pumpEventQueue();
      expect(
        engine.calls,
        ['start', 'stop'],
        reason: 'the stop has not reached the engine while the start is '
            'still out: it is waiting for a start nothing else can end',
      );
      final outcome = await stopping;
      await starting;

      expect(
        engine.calls,
        ['start', 'stop'],
        reason: 'a stop that waited for the start would still be waiting, and '
            'one that stopped it twice would have torn down a second time',
      );
      expect(outcome, LiveSyncStopOutcome.stopped);
      expect(seen, [LiveSyncStopOutcome.stopped], reason: 'reported once');
      expect(engine.disposeCalls, 1);
      expect(engine.foregroundClaims, isEmpty);
      expect(service.isRunning, isFalse);
      expect(startError, isA<SubscriptionServiceException>());
      expect(
        '$startError',
        isNot(contains('failed to start')),
        reason: 'the caller asked for the stop: this is not a failed start',
      );
      expect(logs.joined, isNot(contains('start failed')));
    });

    test('a start whose engine is not built yet builds it and starts nothing',
        () async {
      final building = Completer<_FakeEngine>();
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () => building.future,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();

      var stopped = false;
      final stopping = service.stop().whenComplete(() => stopped = true);
      await pumpEventQueue();
      expect(
        stopped,
        isFalse,
        reason: 'premise: there is no engine to stop yet, so this one waits '
            'for the factory',
      );

      building.complete(engine);
      expect(await starting, isA<SubscriptionServiceException>());
      expect(await stopping, LiveSyncStopOutcome.idle);
      expect(
        engine.calls,
        isEmpty,
        reason: 'the session was started behind a stop that had been asked '
            'for before the engine existed',
      );
      expect(engine.disposeCalls, 1, reason: 'the built handle is released');
      expect(service.isRunning, isFalse);
    });

    test('a start that comes up behind the stop is stopped, never adopted',
        () async {
      // The engine's stop can run before the engine has installed the
      // session it was asked to end. It then stops nothing and the start
      // succeeds.
      final engine = _FakeEngine()
        ..startGate = Completer<void>()
        ..stopEndsStart = false;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      final stopping = service.stop();
      await pumpEventQueue();
      expect(engine.calls, ['start', 'stop'], reason: 'premise');

      engine.startGate!.complete();
      expect(await starting, isA<SubscriptionServiceException>());
      expect(await stopping, LiveSyncStopOutcome.stopped);

      expect(
        engine.calls,
        ['start', 'stop', 'started', 'stop'],
        reason: 'the session that came up is running in the engine with '
            'nothing in Dart holding it',
      );
      expect(engine.foregroundClaims, isEmpty, reason: 'never claimed for');
      expect(engine.disposeCalls, 1);
      expect(service.isRunning, isFalse);
    });

    test('a start that comes up behind the stop and will not stop is reported '
        'as still holding', () async {
      // The stop's own engine call ran before the session was installed, so
      // it answered cleanly having stopped nothing. The session that then
      // came up does not drain: the engine still holds the MLS guard.
      final engine = _FakeEngine()
        ..startGate = Completer<void>()
        ..stopEndsStart = false
        ..failStopOn = const {2, 3};
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      final stopping = service.stop();
      await pumpEventQueue();
      expect(engine.stopCalls, 1, reason: 'premise: answered, nothing stopped');

      engine.startGate!.complete();
      expect(await starting, isA<SubscriptionServiceException>());

      expect(
        await stopping,
        LiveSyncStopOutcome.stillHolding,
        reason: 'the pause reads `stopped` as a session it may hand to the '
            'foreground service, and releases its own handle on a guard the '
            'engine still holds',
      );
      expect(engine.stopCalls, 3);
      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);
    });

    test("the stop's retry runs on a handle the ended start has not released",
        () async {
      final engine = _FakeEngine()
        ..startGate = Completer<void>()
        ..failStopCalls = 1;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();

      expect(
        await service.stop(),
        LiveSyncStopOutcome.stopped,
        reason: 'the start it ended disposed the handle under the retry, '
            'which then could only fail',
      );
      expect(await starting, isA<SubscriptionServiceException>());
      expect(engine.stopCalls, 2);
      expect(engine.disposeCalls, 1);
    });

    test('a stop that never drains is latched through an ended start',
        () async {
      final engine = _FakeEngine()
        ..startGate = Completer<void>()
        ..failStopCalls = 2;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();

      expect(await service.stop(), LiveSyncStopOutcome.stillHolding);
      await starting;
      expect(
        await service.stop(),
        LiveSyncStopOutcome.stillHolding,
        reason: 'the guard is still held, and the next pause must be told so',
      );
    });

    test('a stop issued during a start that fails is not left waiting, and '
        'the service starts again afterwards', () async {
      final failing = _FakeEngine(failStart: true)
        ..startGate = Completer<void>()
        ..stopEndsStart = false;
      final next = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? failing : next,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      final stopping = service.stop();
      failing.startGate!.complete();

      await expectLater(starting, throwsA(isA<SubscriptionServiceException>()));
      expect(await stopping, LiveSyncStopOutcome.stopped);
      expect(failing.stopCalls, 1);
      expect(failing.disposeCalls, 1);
      expect(failing.foregroundClaims, isEmpty);

      // And THIS service starts again afterwards.
      await service.start(groups: const [], inboxRelays: const []);
      expect(service.isRunning, isTrue);
      expect(next.foregroundClaims, [true]);
      await service.stop();
    });

    test('a stop does not wait for a claim the engine is slow to take',
        () async {
      final engine = _FakeEngine()..claimGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      expect(
        engine.calls,
        ['start', 'started', 'claim:true'],
        reason: 'premise: the session is up and its claim is with the engine',
      );

      // The claim's gate is still shut.
      var answered = false;
      final stopping = service.stop().whenComplete(() => answered = true);
      await pumpEventQueue();
      expect(
        answered,
        isTrue,
        reason: 'the stop is waiting for the claim of a session that is '
            "already this service's to stop",
      );
      expect(await stopping, LiveSyncStopOutcome.stopped);
      expect(engine.calls, ['start', 'started', 'claim:true', 'stop']);
      expect(engine.disposeCalls, 1);
      expect(service.isRunning, isFalse);

      engine.claimGate!.complete();
      await expectLater(
        starting,
        throwsA(isA<SubscriptionStartEnded>()),
        reason: 'the start returned normally over an engine a stop had '
            'already taken: its caller adopts a running set with no session',
      );
      expect(service.isRunning, isFalse);
    });

    test('a second stop does not wait for the claim of a start the first '
        'one ended', () async {
      final engine = _FakeEngine()..claimGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      var first = false;
      final firstStop = service.stop().whenComplete(() => first = true);
      await pumpEventQueue();
      expect(first, isTrue, reason: 'premise: the first stop has answered');
      expect(await firstStop, LiveSyncStopOutcome.stopped);

      // The claim is still parked: that start can adopt nothing any more.
      var answered = false;
      final second = service.stop().whenComplete(() => answered = true);
      await pumpEventQueue();
      expect(
        answered,
        isTrue,
        reason: "a second pause's hand-off, or a logout, waited for a claim "
            'on an engine that is already down',
      );
      expect(await second, LiveSyncStopOutcome.idle);
      expect(engine.stopCalls, 1);

      engine.claimGate!.complete();
      expect(await starting, isA<SubscriptionStartEnded>());
    });

    test('a stop ends a later start too, once an earlier one was adopted',
        () async {
      // What says "this start has adopted its engine" is cleared with the
      // start. Left set, the next start's stop finds nothing to end.
      final later = _FakeEngine()..startGate = Completer<void>();
      final queued = [_FakeEngine(), later];
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => queued.removeAt(0),
      );
      await service.start(groups: const [], inboxRelays: const []);
      expect(await service.stop(), LiveSyncStopOutcome.stopped);

      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      expect(later.calls, ['start'], reason: 'premise: still connecting');

      final stopping = service.stop();
      await pumpEventQueue();
      expect(
        later.calls,
        ['start', 'stop'],
        reason: 'the stop found no engine and no start it could end',
      );
      expect(await stopping, LiveSyncStopOutcome.stopped);
      expect(await starting, isA<SubscriptionStartEnded>());
      expect(service.isRunning, isFalse);
    });

    test('a start a stop ends is told apart from one that failed, by type',
        () async {
      final ended = _FakeEngine()..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => ended,
      );
      final starting = service
          .start(groups: const [], inboxRelays: const [])
          .then<Object?>((_) => null, onError: (Object e) => e);
      await pumpEventQueue();
      await service.stop();
      expect(await starting, isA<SubscriptionStartEnded>());

      final failing = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => _FakeEngine(failStart: true),
      );
      Object? failure;
      try {
        await failing.start(groups: const [], inboxRelays: const []);
      } on Object catch (e) {
        failure = e;
      }
      expect(failure, isA<SubscriptionServiceException>());
      expect(failure, isNot(isA<SubscriptionStartEnded>()));
    });

    test('a burst opened during a start waits for it, then opens',
        () async {
      // It used to throw at once on the missing engine: one failed open
      // counted toward a receive fault that is not one, and a publish with no
      // backlog wait in front of it.
      final engine = _FakeEngine()..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      final starting = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();

      Object? openError;
      var opened = false;
      final opening = service
          .openBackgroundBurstWithin(const Duration(seconds: 30))
          .then<void>(
            (_) => opened = true,
            onError: (Object e) => openError = e,
          );
      await pumpEventQueue();
      expect(openError, isNull, reason: 'refused while the session came up');
      expect(opened, isFalse, reason: 'premise: there is no engine yet');

      engine.startGate!.complete();
      await starting;
      await opening;
      expect(opened, isTrue);
      expect(engine.burstOpenCalls, 1);
      await service.stop();
    });

    test('a second start joins the one in flight', () async {
      var factoryCalls = 0;
      final engine = _FakeEngine()..startGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async {
          factoryCalls++;
          return engine;
        },
      );
      final first = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      final second = service.start(groups: const [], inboxRelays: const []);
      await pumpEventQueue();
      expect(
        factoryCalls,
        1,
        reason: 'a second engine was built over the one still starting',
      );

      engine.startGate!.complete();
      await Future.wait([first, second]);
      expect(engine.startCalls, 1);
      expect(engine.foregroundClaims, [true]);
      expect(service.isRunning, isTrue);
      await service.stop();
    });

    test('a stop parked on the first of two overlapping starts ends both',
        () async {
      final building = Completer<_FakeEngine>();
      var factoryCalls = 0;
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () {
          factoryCalls++;
          return building.future;
        },
      );
      Future<Object?> ended(Future<void> start) =>
          start.then<Object?>((_) => null, onError: (Object e) => e);
      final first = ended(
        service.start(groups: const [], inboxRelays: const []),
      );
      final second = ended(
        service.start(groups: const [], inboxRelays: const []),
      );
      final stopping = service.stop();
      await pumpEventQueue();

      building.complete(engine);
      expect(await first, isA<SubscriptionServiceException>());
      expect(await second, isA<SubscriptionServiceException>());
      await stopping;
      expect(factoryCalls, 1);
      expect(engine.startCalls, 0);
      expect(engine.disposeCalls, 1);
      expect(service.isRunning, isFalse);
    });

    test('a second stop joins the one in flight', () async {
      final seen = <LiveSyncStopOutcome>[];
      final engine = _FakeEngine()..stopGate = Completer<void>();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
        onStopOutcome: seen.add,
      );
      await service.start(groups: const [], inboxRelays: const []);
      // A start that succeeded is reported first: it proves the previous
      // session drained.
      expect(seen, [LiveSyncStopOutcome.stopped]);
      seen.clear();

      final first = service.stop();
      await pumpEventQueue();
      var secondAnswered = false;
      final second = service.stop().whenComplete(() => secondAnswered = true);
      await pumpEventQueue();
      expect(
        secondAnswered,
        isFalse,
        reason: 'it answered `idle` while the engine was still stopping: the '
            'handoff reads that as a session it may give away',
      );

      engine.stopGate!.complete();
      expect(await first, LiveSyncStopOutcome.stopped);
      expect(await second, LiveSyncStopOutcome.stopped);
      expect(engine.stopCalls, 1);
      expect(seen, [LiveSyncStopOutcome.stopped]);
    });

    test('a stop given up on answers stillHolding at once and ends its '
        'session Dart-side, before the engine returns', () async {
      final seen = <LiveSyncStopOutcome>[];
      final stopping = _FakeEngine()..stopGate = Completer<void>();
      final fresh = _FakeEngine();
      var built = 0;
      final router = _SpyRouter();
      final service = NostrSubscriptionService(
        router: router,
        engineFactory: () async => built++ == 0 ? stopping : fresh,
        onStopOutcome: seen.add,
      );
      await service.start(groups: const [], inboxRelays: const []);
      // A start that succeeded is reported first: it proves the previous
      // session drained.
      expect(seen, [LiveSyncStopOutcome.stopped]);
      seen.clear();

      final givenUp = Completer<void>();
      final stop = service.stop(givenUp: givenUp.future);
      await pumpEventQueue();
      givenUp.complete();
      expect(await stop, LiveSyncStopOutcome.stillHolding);
      expect(seen, [LiveSyncStopOutcome.stillHolding]);
      stopping.controller.add(_status(FfiSyncStatusReason.connected));
      await pumpEventQueue();
      expect(
        router.seen,
        isEmpty,
        reason: 'the session delivered an event after its stop was given up',
      );
      expect(
        stopping.disposeCalls,
        0,
        reason: 'disposed while its stop was still out on it',
      );
      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(isA<SubscriptionServiceException>()),
      );
      expect(fresh.startCalls, 0, reason: 'adopted across a stop in flight');

      stopping.stopGate!.complete();
      await pumpEventQueue();
      expect(stopping.disposeCalls, 1);
      expect(seen, [
        LiveSyncStopOutcome.stillHolding,
        LiveSyncStopOutcome.stopped,
      ]);
    });

    test('a location queued behind a handler when its identity is forgotten '
        'is dropped', () async {
      // Handlers run one after another, so the identity an event arrived
      // under is taken when it arrives, not when its handler starts.
      final ingested = <DecryptedLocation>[];
      final parsing = Completer<void>();
      final router = _locationRouter(ingested, parsing: parsing);
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: router,
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);
      engine.controller
        ..add(_location('first'))
        ..add(_location('second'));
      await pumpEventQueue();

      router.forgetIdentity();
      parsing.complete();
      await pumpEventQueue();

      expect(
        ingested,
        isEmpty,
        reason: "a location of the deleted identity's session reached the "
            "next identity's location service",
      );
    });

    test('a full restart drops no location still in its handler', () async {
      // Before: every stop dropped it whole. The same identity's location
      // service is still the target, and its own fences decide.
      final ingested = <DecryptedLocation>[];
      final parsing = Completer<void>();
      final engine = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _locationRouter(ingested, parsing: parsing),
        engineFactory: () async => built++ == 0 ? engine : _FakeEngine(),
      );
      await service.start(groups: const [], inboxRelays: const []);
      engine.controller.add(_location('peer'));
      await pumpEventQueue();

      await service.stop();
      await service.start(groups: const [], inboxRelays: const []);
      parsing.complete();
      await pumpEventQueue();

      expect(
        ingested.map((l) => l.senderPubkey),
        ['peer'],
        reason: 'a foreground restart lost a peer fix until its next publish',
      );
    });

    test('a start asked for while a stop is in flight brings nothing up',
        () async {
      final stopping = _FakeEngine()..stopGate = Completer<void>();
      final fresh = _FakeEngine();
      var built = 0;
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => built++ == 0 ? stopping : fresh,
      );
      await service.start(groups: const [], inboxRelays: const []);
      final stop = service.stop();
      await pumpEventQueue();

      await expectLater(
        service.start(groups: const [], inboxRelays: const []),
        throwsA(isA<SubscriptionServiceException>()),
      );
      expect(
        fresh.startCalls,
        0,
        reason: 'a second session was started over one still being torn '
            'down, on the same MLS state',
      );
      expect(fresh.disposeCalls, 1);

      stopping.stopGate!.complete();
      await stop;
      expect(service.isRunning, isFalse);
    });

    test('a deliberate stop still clears the engine in the call that asked',
        () async {
      // `_onStreamClosed` tells a deliberate stop from a death by finding no
      // engine: the stop that ends the stream must already have cleared it.
      final engine = _FakeEngine();
      final service = NostrSubscriptionService(
        router: _SpyRouter(),
        engineFactory: () async => engine,
      );
      await service.start(groups: const [], inboxRelays: const []);

      final stopping = service.stop();
      expect(
        service.isRunning,
        isFalse,
        reason: 'the engine was still held one turn after the stop was asked',
      );
      await stopping;
      expect(engine.stopCalls, 1);
    });
  });

  group('the strict lifecycle read', () {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    tearDown(
      () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );

    void enter(AppLifecycleState? state) {
      binding.resetInternalState();
      if (state != null) binding.handleAppLifecycleStateChanged(state);
      expect(binding.lifecycleState, state, reason: 'premise');
    }

    test('appIsResumed is the strict read appIsForegrounded is not', () {
      // The two answer differently exactly where it matters: before the first
      // lifecycle event. `appIsForegrounded` says yes so that startup work is
      // not lost; `appIsResumed` says no so that nothing is claimed.
      enter(null);
      expect(appIsForegrounded(), isTrue);
      expect(appIsResumed(), isFalse);
      for (final state in AppLifecycleState.values) {
        enter(state);
        expect(
          appIsResumed(),
          state == AppLifecycleState.resumed,
          reason: 'appIsResumed in ${state.name}',
        );
      }
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
