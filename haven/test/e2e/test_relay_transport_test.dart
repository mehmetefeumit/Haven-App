/// Host-side proof that `TestRelay` survives — and does not paper over — a
/// socket the network orphaned underneath it.
///
/// ## The failure this pins
///
/// On CI run 31868809387 the Android emulator destroyed its default network in
/// the middle of the core-flow lane (`networkDestroy(100)` in logcat, three
/// seconds before a replacement network appeared). Every socket bound to it was
/// orphaned: no FIN reached the host, no close event reached Dart, and
/// `sink.add` kept succeeding into a connection that could never deliver.
///
/// Two things then failed, both on that one socket. A synthetic peer's leave
/// commit timed out waiting for an OK the relay was never asked for, and the
/// wire-journal sentinel timed out waiting for an ack from a recording proxy
/// that never saw the frame — reporting "either this run pointed the app
/// straight at strfry, or the proxy is not recording" when neither was true.
/// The wire journal for that run proves it: the run's sentinel token appears
/// nowhere in it, and the socket's last recorded frame is far earlier.
///
/// ## What is asserted here, and what is deliberately not
///
/// The orphaned socket is reproduced exactly — a TCP splice that stops moving
/// bytes in both directions without closing either end — so these tests fail
/// if the liveness ping is removed, if it is slowed past the point where the
/// sentinel budget can absorb a reconnect, or if a control frame stops being
/// re-issued on the fresh socket.
///
/// The opposite direction matters just as much and is pinned too: a frame that
/// IS delivered and goes unanswered must still fail at its stated budget.
/// That silence is what an absent recorder looks like, and the wire oracles
/// fail closed on it. Retrying it, or waiting longer for it, would turn a
/// fail-closed oracle into a slow one — so both waits below assert that the
/// failure arrives on time and only once.
///
/// Runs under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/test_relay.dart';

/// Fast enough to keep these tests short, and the only reason
/// `TestRelay.connect` takes the interval at all.
const Duration _fastPing = Duration(milliseconds: 200);

/// Comfortably past detection (2 x [_fastPing]) plus one reconnect backoff.
const Duration _recoveryBudget = Duration(seconds: 8);

void main() {
  late _FakeRecorder recorder;
  late _Splice splice;
  late TestRelay relay;

  setUp(() async {
    recorder = await _FakeRecorder.start();
    splice = await _Splice.start(recorder.port);
  });

  tearDown(() async {
    await relay.dispose();
    await splice.stop();
    await recorder.stop();
  });

  Future<void> connect() async {
    relay = await TestRelay.connect(
      url: 'ws://127.0.0.1:${splice.port}',
      pingInterval: _fastPing,
    );
  }

  group('the liveness check is armed', () {
    test('the live socket carries the ping interval', () async {
      await connect();
      expect(
        relay.livenessPingInterval,
        _fastPing,
        reason: 'read back off the dart:io socket, not off a copy of what was '
            'requested: an unset interval leaves an orphaned socket '
            'indistinguishable from an idle one forever',
      );
    });

    test('a reconnected socket carries it too', () async {
      await connect();
      await relay.emitWireJournalSentinel(
        token: 'first',
        timeout: _fastPing * 5,
      );

      splice.orphanOpenConnections();
      // Any exchange drives the detect-and-reconnect cycle.
      await relay.emitWireJournalSentinel(
        token: 'second',
        timeout: _recoveryBudget,
      );

      expect(
        relay.livenessPingInterval,
        _fastPing,
        reason: 'a socket that replaced an orphaned one can be orphaned in '
            'turn; losing the interval on reconnect would make the second '
            'outage undetectable',
      );
    });

    test('detection plus a reconnect fits inside the sentinel budget', () {
      // The default sentinel budget in `emitWireJournalSentinel`. Twice the
      // ping interval is the worst-case time to notice an orphaned socket
      // (dart:io pings every interval and closes when the pong misses the
      // next one); the first reconnect backoff is 1 s. Raising the interval
      // past this point would leave the marker failing on a socket nothing
      // has yet noticed is dead — the exact CI failure, just slower.
      const sentinelBudget = Duration(seconds: 15);
      expect(
        TestRelay.socketPingInterval * 2 + const Duration(seconds: 1),
        lessThan(sentinelBudget),
      );
    });
  });

  group('an orphaned socket is recovered, not lost', () {
    test('the journal sentinel is re-emitted on the fresh socket', () async {
      await connect();
      // Prove the path is healthy first, so the failure below is the outage
      // and not a broken fixture.
      final before = await relay.emitWireJournalSentinel(
        token: 'healthy',
        timeout: _fastPing * 5,
      );
      expect(before.token, 'healthy');

      splice.orphanOpenConnections();
      final recovered = await relay.emitWireJournalSentinel(
        token: 'after-the-outage',
        timeout: _recoveryBudget,
      );

      expect(recovered.token, 'after-the-outage');
      expect(
        recorder.sentinelTokens,
        contains('after-the-outage'),
        reason: 'the marker has to reach the recorder, not merely stop '
            'throwing: a sentinel that never lands leaves the host oracles '
            'unable to tell a quiet journal from one that never saw the run',
      );
      expect(
        recorder.connectionCount,
        greaterThan(1),
        reason: 'recovery must come from a NEW connection — the orphaned one '
            'can never deliver anything again',
      );
    });

    test('a publish is re-published on the fresh socket', () async {
      await connect();
      splice.orphanOpenConnections();

      final (accepted, _) = await relay
          .publishAndAwaitOk(_event('a1'))
          .timeout(_recoveryBudget);

      expect(accepted, isTrue);
      expect(
        recorder.publishedEventIds,
        contains('a1'),
        reason: 'the event has to reach the relay; a publish that only stops '
            'throwing would leave the scenario asserting against traffic that '
            'never happened',
      );
    });
  });

  group('a delivered frame that goes unanswered still fails on time', () {
    test('the sentinel fails at its budget and is not retried', () async {
      recorder.answerSentinels = false;
      await connect();

      final started = DateTime.now();
      await expectLater(
        relay.emitWireJournalSentinel(
          token: 'unanswered',
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<StateError>()),
      );
      final elapsed = DateTime.now().difference(started);

      expect(
        recorder.sentinelTokens.where((t) => t == 'unanswered').length,
        1,
        reason: 'a silent recorder is exactly what the oracle fails closed on. '
            'Re-emitting here would spend the budget several times over and '
            'turn a fail-closed check into a slow one',
      );
      expect(
        elapsed,
        lessThan(const Duration(seconds: 3)),
        reason: 'the budget bounds a LIVE socket holding a frame unanswered; '
            'nothing may stretch it',
      );
    });

    test('a publish fails at its budget, and reports the failure once',
        () async {
      // The second half is a regression: the old shape derived a future from
      // the OK completer purely to cancel a timer, and nothing awaited that
      // derived future. Every failure was therefore also delivered to the zone
      // as an unhandled error — which reads in a lane log as the same
      // exception "thrown after the test had completed", and fails THIS test
      // if it comes back.
      recorder.answerPublishes = false;
      await connect();

      await expectLater(
        relay.publishAndAwaitOk(
          _event('b1'),
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );

      // Long enough for a stray unhandled error to reach the zone.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        recorder.publishedEventIds.where((id) => id == 'b1').length,
        1,
        reason: 'an unanswered publish proves nothing about delivery, so it '
            'must not be re-published',
      );
    });
  });
}

/// A minimal signed-shaped Nostr event; only `id` is read by `TestRelay`.
String _event(String id) => jsonEncode(<String, dynamic>{
      'id': id,
      'pubkey': '00' * 32,
      'created_at': 0,
      'kind': 1,
      'tags': <List<String>>[],
      'content': '',
      'sig': '00' * 64,
    });

/// Stands in for the recording proxy: answers the sentinel verb and OKs
/// events, and can be told to answer neither.
class _FakeRecorder {
  _FakeRecorder._(this._server) {
    unawaited(_serve());
  }

  static Future<_FakeRecorder> start() async =>
      _FakeRecorder._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// Sentinel tokens observed, in arrival order.
  final List<String> sentinelTokens = <String>[];

  /// Event ids observed, in arrival order.
  final List<String> publishedEventIds = <String>[];

  /// Connections accepted so far.
  int connectionCount = 0;

  /// When false the sentinel is received and deliberately left unanswered.
  bool answerSentinels = true;

  /// When false an event is received and deliberately left un-OK'd.
  bool answerPublishes = true;

  int get port => _server.port;

  Future<void> _serve() async {
    await for (final request in _server) {
      final socket = await WebSocketTransformer.upgrade(request);
      connectionCount += 1;
      socket.listen((dynamic data) {
        if (data is! String) return;
        final dynamic decoded = jsonDecode(data);
        if (decoded is! List || decoded.isEmpty) return;
        switch (decoded.first) {
          case 'HAVEN_WIRE_SENTINEL':
            final token = decoded[1] as String;
            sentinelTokens.add(token);
            if (answerSentinels) {
              socket.add(
                jsonEncode(<dynamic>[
                  'HAVEN_WIRE_SENTINEL_ACK',
                  token,
                  sentinelTokens.length,
                  'c0',
                ]),
              );
            }
          case 'EVENT':
            final event = decoded[1] as Map<String, dynamic>;
            final id = event['id'] as String;
            publishedEventIds.add(id);
            if (answerPublishes) {
              socket.add(jsonEncode(<dynamic>['OK', id, true, '']));
            }
        }
      }, onError: (Object _) {}, cancelOnError: false);
    }
  }

  Future<void> stop() => _server.close(force: true);
}

/// A TCP splice that can stop moving bytes in BOTH directions without closing
/// either end.
///
/// That is the shape an Android `networkDestroy` leaves behind, and the reason
/// the failure it causes is invisible: the peers hold open sockets that can
/// never deliver, and neither ever hears about it. Connections opened AFTER
/// [orphanOpenConnections] work normally — the emulator built a replacement
/// network three seconds later, and every socket made on it was fine.
class _Splice {
  _Splice._(this._server, this._upstreamPort) {
    unawaited(_serve());
  }

  static Future<_Splice> start(int upstreamPort) async => _Splice._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
        upstreamPort,
      );

  final ServerSocket _server;
  final int _upstreamPort;
  final List<_SplicedPair> _pairs = <_SplicedPair>[];

  int get port => _server.port;

  /// Strands every connection currently open, leaving both ends unaware.
  void orphanOpenConnections() {
    for (final pair in _pairs) {
      pair.orphaned = true;
    }
  }

  Future<void> _serve() async {
    await for (final downstream in _server) {
      final upstream = await Socket.connect(
        InternetAddress.loopbackIPv4,
        _upstreamPort,
      );
      final pair = _SplicedPair();
      _pairs.add(pair);
      downstream.listen(
        (data) {
          if (!pair.orphaned) upstream.add(data);
        },
        onError: (Object _) {},
        onDone: () => unawaited(upstream.close().catchError((Object _) {})),
        cancelOnError: false,
      );
      upstream.listen(
        (data) {
          if (!pair.orphaned) downstream.add(data);
        },
        onError: (Object _) {},
        onDone: () => unawaited(downstream.close().catchError((Object _) {})),
        cancelOnError: false,
      );
    }
  }

  Future<void> stop() => _server.close();
}

/// One spliced connection's state.
class _SplicedPair {
  bool orphaned = false;
}
