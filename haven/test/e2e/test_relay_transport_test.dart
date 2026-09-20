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
/// CI run 35311161479 hit the same `networkDestroy` two seconds before a
/// synthetic peer published its SelfRemove leave proposal, and showed that
/// surviving the outage needs more than the liveness ping: the OK wait gave up
/// 5 s in, five seconds before the ping schedule could rule the socket dead, so
/// the re-issue that the earlier fix built was never reached and the failure
/// named the relay. The journal for that run holds no `c2r` frame carrying the
/// proposal on any connection, and the relay's own byte counters for that
/// socket agree. Hence the pair of tests below whose answer budget is shorter
/// than detection: recovery must not depend on the caller having asked for a
/// wait longer than the transport needs.
///
/// ## What is asserted here, and what is deliberately not
///
/// The orphaned socket is reproduced exactly — a TCP splice that stops moving
/// bytes in both directions without closing either end — so these tests fail
/// if the liveness ping is removed, if an answer wait stops being held open
/// until that ping can render its verdict, or if a frame stops being re-issued
/// on the fresh socket.
///
/// The opposite direction matters just as much and is pinned too: a frame that
/// IS delivered and goes unanswered must still fail, promptly and once. That
/// silence is what an absent recorder looks like, and the wire oracles fail
/// closed on it; retrying it, or waiting past the point where it is decidable,
/// would turn a fail-closed oracle into a slow one. So the waits below assert
/// both edges of the bound — silence under the verdict window is raised to it,
/// silence over it is not stretched further.
///
/// Only the publish and the journal-sentinel waits are reachable from here.
/// The MLS-group-id, needle-declaration and canary-manifest waits sit behind
/// `wireRecorderDeclared`, a COMPILE-time gate that a plain `flutter test`
/// leaves false (`log_needles_test.dart`'s doc records the same limit and what
/// covers it instead). They take the same floor from the same helper.
///
/// The sentinel is the one of those gates BOTH of whose branches are reachable
/// here, because it is asked of the token being written rather than of the
/// compiled-in one: a test that supplies its own token is a declared recorder,
/// and the parameter's default is the undeclared lane verbatim. The last group
/// pins both — what an unproxied lane must never put on a relay socket, and
/// the exact frame a proxied one does.
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

/// An answer budget deliberately SHORTER than the time it takes to notice an
/// orphaned socket (2 x [_fastPing]).
///
/// Reproduces the ORDERING the shipped constants have: `publishAndAwaitOk`
/// gives the relay 5 s to answer, while [TestRelay.socketPingInterval] puts
/// the transport's verdict up to 10 s out. Silence below the verdict is
/// evidence of nothing, whatever the absolute numbers are.
const Duration _budgetBelowDetection = Duration(milliseconds: 50);

/// The floor `TestRelay` puts under every answer wait, at [_fastPing].
///
/// Two ping intervals is the worst case for the transport to report a peer
/// that vanished without a FIN; the extra second is the slack that keeps two
/// timers due at the same instant from deciding the outcome between them.
/// Written out here as an INDEPENDENT expected value, never read back off
/// `TestRelay`: a test that took the number from the same expression it is
/// checking would agree with any value that expression ever produces,
/// including a wrong one.
final Duration _verdictWindow = _fastPing * 2 + const Duration(seconds: 1);

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

    test('a live wait really is held open to the verdict window', () async {
      // The arithmetic is pinned below, without a clock. What THIS adds is
      // that the rule is actually applied to a real wait rather than merely
      // computed: the socket is live and the recorder simply never answers,
      // so nothing dies and nothing is re-issued, and the failure still
      // cannot arrive before the window.
      //
      // The bound is one-sided on purpose. A `.timeout(d)` cannot fire before
      // `d`, so this holds by construction on any runner; an upper bound here
      // would let a loaded machine decide the verdict instead of the code.
      recorder.answerSentinels = false;
      await connect();

      final started = DateTime.now();
      await expectLater(
        relay.emitWireJournalSentinel(
          token: 'under',
          timeout: _budgetBelowDetection,
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(_verdictWindow),
        reason: 'failing at the caller budget would call an undelivered '
            'frame unanswered and leave the re-issue unreached',
      );
    });
  });

  group('the answer floor is arithmetic, not a wall clock', () {
    // Which of two different quantities bounds an answer wait. The caller's
    // budget says how long the RELAY or the recorder may take to answer a
    // frame it holds; the transport needs up to two ping intervals to report
    // a peer that vanished, and silence shorter than that is evidence of
    // neither outcome. So the wait is the longer of the two: raising the
    // shorter budget is what makes an orphan detectable at all, and NOT
    // raising the longer one is what keeps a fail-closed oracle as prompt as
    // it says it is.

    test('a budget under the transport verdict is raised to it', () {
      expect(
        TestRelay.answerBudget(_budgetBelowDetection, _fastPing),
        _verdictWindow,
      );
    });

    test('a budget over it is returned untouched', () {
      final over = _verdictWindow * 2;
      expect(
        TestRelay.answerBudget(over, _fastPing),
        over,
        reason: 'a floor that stacked on top of a budget already clearing '
            'the verdict would make every unanswered frame in this class '
            'slower than its documented budget',
      );
    });

    test('the shipped constants put the publish default under the floor', () {
      // The production case, in production numbers: a 5 s budget against a
      // 10 s verdict. That ordering is the CI failure — and the reason the
      // floor cannot be left to the caller's default.
      expect(
        TestRelay.answerBudget(
          const Duration(seconds: 5),
          TestRelay.socketPingInterval,
        ),
        const Duration(seconds: 11),
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

    test('a publish whose budget expires before detection is re-published, '
        'not blamed on the relay', () async {
      await connect();
      splice.orphanOpenConnections();

      final (accepted, _) = await relay
          .publishAndAwaitOk(_event('a2'), timeout: _budgetBelowDetection)
          .timeout(_recoveryBudget);

      expect(accepted, isTrue);
      expect(
        recorder.publishedEventIds.where((id) => id == 'a2').length,
        1,
        reason: 'silence shorter than the transport verdict is evidence of '
            'nothing. Reading it as "the relay ignored the frame" leaves the '
            'orphan undetected and the re-issue unreached — CI run '
            "35311161479 lost a peer's SelfRemove leave proposal exactly "
            'there, giving up 5 s into a verdict that takes up to 10 s',
      );
      expect(
        recorder.connectionCount,
        greaterThan(1),
        reason: 'the retry has to land on a NEW connection; re-writing the '
            'orphaned one would look identical from here and deliver nothing',
      );
    });

    test('the journal sentinel is re-emitted when its budget expires before '
        'detection too', () async {
      // The floor is one shared helper, but it is applied per wait, and the
      // sentinel is the second of the two waits a plain `flutter test` can
      // reach (the MLS-group-id, needle and canary waits are behind the
      // compile-time recorder gate — see `log_needles_test.dart`'s doc). The
      // consequence here is sharper than a lost publish: a marker that never
      // reaches the recorder makes the host oracle report "this run was not
      // proxied", which is a true-looking verdict about the wrong subject.
      await connect();
      splice.orphanOpenConnections();

      final recovered = await relay
          .emitWireJournalSentinel(
            token: 'short-budget',
            timeout: _budgetBelowDetection,
          )
          .timeout(_recoveryBudget);

      expect(recovered.token, 'short-budget');
      expect(
        recorder.sentinelTokens.where((t) => t == 'short-budget').length,
        1,
        reason: 'the marker has to reach the recorder exactly once — the '
            'orphaned socket delivered nothing, so a second copy here would '
            'mean the fresh socket was written to twice',
      );
      expect(
        recorder.connectionCount,
        greaterThan(1),
        reason: 'recovery must come from a NEW connection',
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
        reason: 'a live socket that simply does not answer fails promptly: '
            'the wait is the larger of this budget and the transport verdict '
            'window, and nothing beyond either. A re-emission or a wait for a '
            'fresh socket would show up here as a multiple of them',
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

    test('a budget shorter than detection still fails on a live socket',
        () async {
      recorder.answerPublishes = false;
      await connect();

      await expectLater(
        relay.publishAndAwaitOk(
          _event('b2'),
          timeout: _budgetBelowDetection,
        ),
        throwsA(isA<TimeoutException>()),
      );

      expect(
        recorder.publishedEventIds.where((id) => id == 'b2').length,
        1,
        reason: 'waiting out the transport verdict must never become a '
            'retry: a socket that is demonstrably alive and simply does not '
            'answer still fails, and the frame goes out exactly once',
      );
    });
  });

  group('the recorder gate — the compiled default token is not traffic', () {
    // `wireRecorderDeclared` is false throughout this suite
    // (`log_needles_test.dart` pins that), so the parameter's default IS what
    // an unproxied lane compiles: `e2e-flakiness-stress.yml` drives
    // e2e_combined straight at strfry with no recorder anywhere in path.

    test('the default token is refused, and no frame is written', () async {
      await connect();

      await expectLater(
        relay.emitWireJournalSentinel(),
        throwsA(isA<StateError>()),
      );

      // Ordering, not timing: one connection delivers in order, so a frame
      // the refused call had written would already be in `frames` by the time
      // this one is acked.
      await relay.emitWireJournalSentinel(
        token: 'after-the-refusal',
        timeout: _fastPing * 5,
      );

      expect(
        recorder.frames,
        <Object?>[
          <Object?>['HAVEN_WIRE_SENTINEL', 'after-the-refusal'],
        ],
        reason: 'a harness verb has no business on a relay that is not the '
            'recorder, and the ack it would then wait out its whole budget '
            'for cannot come from anything — a scenario reported as failed '
            'every night while measuring nothing',
      );
    });

    test('the refusal waits for nothing', () async {
      // A recorder that answers no sentinel: were the gate BELOW the write,
      // this call would sit on its answer budget instead of settling.
      recorder.answerSentinels = false;
      await connect();

      var settled = false;
      final refusal = relay
          .emitWireJournalSentinel()
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => settled = true);

      // One event-loop turn, not a duration: the microtask queue is fully
      // drained before a zero-duration timer runs, while every wait in
      // `TestRelay` is a timer of at least a second. So this is a
      // deterministic "was a timer armed?" probe, not a race a loaded runner
      // can lose.
      await Future<void>.delayed(Duration.zero);

      expect(
        settled,
        isTrue,
        reason: 'the gate is the first statement of the emit — ahead of the '
            'closed check, the writability poll and the ack wait',
      );
      await refusal;
    });

    test('a declared token writes exactly the sentinel frame', () async {
      await connect();

      final ack = await relay.emitWireJournalSentinel(
        token: 'declared',
        timeout: _fastPing * 5,
      );

      expect(ack.token, 'declared');
      expect(
        recorder.frames,
        <Object?>[
          <Object?>['HAVEN_WIRE_SENTINEL', 'declared'],
        ],
        reason: 'the proxy intercepts on the verb in position 0 and acks on '
            'the token in position 1 (frame.rs); anything else about this '
            'frame would be forwarded upstream to the relay instead',
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

  /// Every frame observed, decoded, in arrival order.
  ///
  /// [sentinelTokens] answers "did the marker land?"; this answers "was
  /// anything written at all, and was it exactly the frame the proxy parses?"
  /// — the two questions the recorder gate is made of. `TestRelay` only ever
  /// writes `jsonEncode`d arrays, so a decoded frame is the whole write.
  final List<Object?> frames = <Object?>[];

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
        frames.add(decoded);
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
