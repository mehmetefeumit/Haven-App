import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_subscription_service.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

/// A fake [LiveSyncFfi] engine. Only the 7 methods the service drives are
/// overridden; everything else (the `RustOpaqueInterface` internals) routes to
/// [noSuchMethod] and is never called by the service.
class _FakeEngine implements LiveSyncFfi {
  _FakeEngine({
    this.failStart = false,
    this.failSubscribe = false,
    this.failUnsubscribe = false,
  });

  /// When true, [startSession] throws (with a hex-like detail, to prove the
  /// service never leaks it — Security Rule 8).
  final bool failStart;

  /// When true, [subscribeCircle] throws — the delta-op counterpart to
  /// [failStart].
  final bool failSubscribe;

  /// When true, [unsubscribeCircle] throws — the delta-op counterpart to
  /// [failStart].
  final bool failUnsubscribe;

  final StreamController<FfiRelayEvent> controller =
      StreamController<FfiRelayEvent>();
  int startCalls = 0;
  int stopCalls = 0;
  int resumeCalls = 0;
  int subscribeCalls = 0;
  int unsubscribeCalls = 0;
  bool _running = false;

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
  Stream<FfiRelayEvent> liveEvents() => controller.stream;

  @override
  bool isRunning() => _running;

  @override
  Future<void> stopSession() async {
    stopCalls++;
    _running = false;
  }

  @override
  Future<void> resumeAfterBackground() async {
    resumeCalls++;
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
}
