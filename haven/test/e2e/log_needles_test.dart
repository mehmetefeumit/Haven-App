/// Host-side proof for `LogNeedles` (Phase 0b of the soak plan): the frame
/// shape the runtime log-privacy scanner's declaration channel sends, the
/// plant token's structural-immunity property, and the recorder gate.
///
/// ## What is NOT proven here, and why
///
/// The live round trip — a frame reaching the recording proxy and its ack
/// resolving `TestRelay.declareNeedle`/`announceCanaryManifest`'s pending
/// completer — is gated behind `wireRecorderDeclared`, a value baked in at
/// COMPILE time from `--dart-define=HAVEN_WIRE_SENTINEL=…`. A plain
/// `flutter test` invocation (this file's gate) compiles with no such define,
/// so `wireRecorderDeclared` is false throughout the run and every gated send
/// path is unreachable from here — exactly the same gap
/// `TestRelay.announceMlsGroupId`'s own round trip has today (see
/// `test_relay_mls_group_id_test.dart`'s doc: "the send path itself needs an
/// emulator, a relay and the proxy, so it runs only in an E2E lane"). What
/// PROVES the live round trip is the local-relay crate's own self-test (a
/// DECL frame driven through each proxy binary, per the Phase 0b brief §3.1)
/// and the E2E lane itself.
///
/// What this file proves instead, all reachable with `wireRecorderDeclared`
/// false (the default): the exact declaration/plant payload shape a host or
/// proxy test can assert against; that a plant token can never itself trip
/// the hex-run structural rule either scanner applies; and the two
/// recorder-gate contracts — `declare`/`plant` are a silent no-op,
/// `announceCanaryManifest` throws — with NEITHER ever writing a byte to the
/// wire when undeclared.
///
/// Runs under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/log_needles.dart';
import '../../integration_test/e2e/_lib/test_relay.dart';
import '../helpers/log_capture.dart';

/// Every character a plant token's random suffix may contain.
const String _kAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// The subset of [_kAlphabet] that reads as a hex digit in either case.
const String _kHexValid = 'ABCDEF23456789';

/// One sliding 4-character window of [s] contains a character OUTSIDE
/// [_kHexValid] — the property that keeps a contiguous hex-valid run from
/// ever reaching 4 characters, in a string of any length.
bool _every4WindowHasANonHexChar(String s) {
  for (var start = 0; start + 4 <= s.length; start++) {
    final window = s.substring(start, start + 4);
    if (!window.split('').any((c) => !_kHexValid.contains(c))) return false;
  }
  return true;
}

void main() {
  test('this suite compiles with no recording proxy declared', () {
    // Pins the assumption every other test in this file depends on: without
    // it, the no-op/throw assertions below would be testing the wrong
    // branch entirely and silently proving nothing.
    expect(wireRecorderDeclared, isFalse);
  });

  group('declaration payload shape (frame text)', () {
    test('declare() payload is exactly {class, value}', () {
      expect(
        needleDeclPayload(needleClass: 'pubkey', value: 'npub1abc'),
        <String, String>{'class': 'pubkey', 'value': 'npub1abc'},
      );
    });

    test('the payload never carries the proxy-reserved keys', () {
      // `needles.rs`'s `RESERVED_KEYS` (`role`, `seq`) are appended by the
      // proxy itself; a caller-supplied payload carrying either is refused
      // with no ack. Neither `needleDeclPayload` nor `plantDeclPayload` can
      // produce one — pinned so a future field addition cannot collide.
      final decl = needleDeclPayload(needleClass: 'role', value: 'seq');
      expect(decl.keys, containsAll(<String>['class', 'value']));
      expect(decl.containsKey('role'), isFalse);
      expect(decl.containsKey('seq'), isFalse);
    });

    test('plant() declaration payload carries class/sink/phase/value', () {
      expect(
        plantDeclPayload(phase: 'open', token: 'logscan-plant-dart-open-X'),
        <String, String>{
          'class': 'plant',
          'sink': 'dart',
          'phase': 'open',
          'value': 'logscan-plant-dart-open-X',
        },
      );
    });

    test('the frame the proxy parses is ["HAVEN_NEEDLE_DECL", <payload>]',
        () {
      final payload = needleDeclPayload(needleClass: 'event_id', value: 'ab');
      final frame = jsonEncode(<dynamic>['HAVEN_NEEDLE_DECL', payload]);
      expect(
        jsonDecode(frame),
        <dynamic>[
          'HAVEN_NEEDLE_DECL',
          <String, String>{'class': 'event_id', 'value': 'ab'},
        ],
      );
    });
  });

  group('plant token shape', () {
    test('matches logscan-plant-dart-<phase>-<10 chars from the alphabet>',
        () async {
      final relay = await _connectedFakeRelay();
      final log = LogCapture();
      try {
        final needles = LogNeedles(relay.relay);
        await needles.plant('open');
        expect(log.lines, hasLength(1));
        final token = log.lines.single!;
        expect(
          RegExp('^logscan-plant-dart-open-[$_kAlphabet]{10}\$')
              .hasMatch(token),
          isTrue,
          reason: 'got "$token"',
        );
      } finally {
        log.restore();
        await relay.dispose();
      }
    });

    test('the "close" phase mints a distinctly-labelled token', () async {
      final relay = await _connectedFakeRelay();
      final log = LogCapture();
      try {
        final needles = LogNeedles(relay.relay);
        await needles.plant('close');
        expect(log.lines.single, startsWith('logscan-plant-dart-close-'));
      } finally {
        log.restore();
        await relay.dispose();
      }
    });

    test(
      'every plant token is immune to a hex-run structural rule BY '
      'CONSTRUCTION — sampled, not asserted once, because the guarantee is '
      'meant to hold for every draw',
      () async {
        final relay = await _connectedFakeRelay();
        final log = LogCapture();
        try {
          final needles = LogNeedles(relay.relay);
          for (var i = 0; i < 200; i++) {
            await needles.plant('open');
            final token = log.lines.last!;
            final suffix = token.split('-').last;
            expect(suffix, hasLength(10));
            expect(
              _every4WindowHasANonHexChar(suffix),
              isTrue,
              reason: 'token "$token" has a hex-run-shaped 4-char window',
            );
          }
          expect(log.lines, hasLength(200));
        } finally {
          log.restore();
          await relay.dispose();
        }
      },
    );

    test('two plants of the same phase mint different tokens', () async {
      final relay = await _connectedFakeRelay();
      final log = LogCapture();
      try {
        final needles = LogNeedles(relay.relay);
        await needles.plant('open');
        await needles.plant('open');
        expect(log.lines, hasLength(2));
        expect(log.lines[0], isNot(log.lines[1]));
      } finally {
        log.restore();
        await relay.dispose();
      }
    });
  });

  group("the recorder gate — no proxy declared (this suite's default)", () {
    test('declare() is a silent no-op: it returns and sends nothing',
        () async {
      final relay = await _connectedFakeRelay();
      try {
        final needles = LogNeedles(relay.relay);
        await needles.declare('pubkey', 'npub1shouldneverbesent');
        expect(
          relay.received,
          isEmpty,
          reason: 'an unproxied lane has no sidecar for this value to '
              'reach; sending it anyway would be pointless traffic against '
              'a real relay in production use',
        );
      } finally {
        await relay.dispose();
      }
    });

    test('plant() still prints its token but sends nothing over the wire',
        () async {
      final relay = await _connectedFakeRelay();
      final log = LogCapture();
      try {
        final needles = LogNeedles(relay.relay);
        await needles.plant('open');
        expect(log.lines, hasLength(1));
        expect(
          relay.received,
          isEmpty,
          reason: 'plants prove sink reach on logcat/drive even when no '
              'recorder is in path; the declare half is still a no-op',
        );
      } finally {
        log.restore();
        await relay.dispose();
      }
    });

    test(
      'announceCanaryManifest() throws BEFORE writing anything, unlike '
      'declare()/plant()',
      () async {
        final relay = await _connectedFakeRelay();
        try {
          final needles = LogNeedles(relay.relay);
          await expectLater(
            needles.announceCanaryManifest(<String, Object?>{
              'role': 'alice',
              'circle_display_name': 'should-never-be-sent',
            }),
            throwsA(isA<StateError>()),
          );
          expect(
            relay.received,
            isEmpty,
            reason: 'the manifest carries canary content meant only for the '
                'host oracle; there is no legitimate reason to send it to '
                'an actual relay, so this fails loud rather than dropping '
                'it quietly like a needle declaration would',
          );
        } finally {
          await relay.dispose();
        }
      },
    );
  });
}

/// A [TestRelay] connected to an in-process fake WebSocket server that
/// records every frame it receives and answers none of them — sufficient for
/// asserting "nothing was sent", which is all these tests need from it.
class _FakeRelayHandle {
  _FakeRelayHandle._(this._server, this.relay, this.received);

  static Future<_FakeRelayHandle> connect() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <dynamic>[];
    unawaited(_serve(server, received));
    final relay = await TestRelay.connect(
      url: 'ws://127.0.0.1:${server.port}',
    );
    return _FakeRelayHandle._(server, relay, received);
  }

  final HttpServer _server;
  final TestRelay relay;

  /// Every frame this fake server has observed, decoded.
  final List<dynamic> received;

  static Future<void> _serve(HttpServer server, List<dynamic> received) async {
    await for (final request in server) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen(
        (dynamic data) {
          if (data is! String) return;
          try {
            received.add(jsonDecode(data));
          } on FormatException {
            received.add(data);
          }
        },
        onError: (Object _) {},
        cancelOnError: false,
      );
    }
  }

  Future<void> dispose() async {
    await relay.dispose();
    await _server.close(force: true);
  }
}

Future<_FakeRelayHandle> _connectedFakeRelay() => _FakeRelayHandle.connect();
