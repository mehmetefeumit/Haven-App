/// Host-side proof that a circle's routing declaration is validated BEFORE it
/// is written to the recording proxy, and that its shape is the one the
/// relay-plane oracle (`haven-wire-planes`, C8) reads.
///
/// `TestRelay.declareCircleRouting` sends
/// `["HAVEN_WIRE_SENTINEL","HAVEN_WIRE_ROUTING:<n>",{"h":…,"relays":[…]}]`.
/// The oracle refuses a malformed payload as UNUSABLE (rc 3) for the whole run
/// and maps a routing relay to a proxy listen by its explicit port, so the
/// encoder is the one place a bad declaration can be stopped with the blame on
/// the caller. The send path itself needs a proxy and runs only in the lanes;
/// the gate in front of it is pinned in `test_relay_transport_test.dart`.
///
/// Runs under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/test_relay.dart';

/// A realistic `nostr_group_id`: 32 bytes, distinctive when hex-encoded.
List<int> _groupId() => List<int>.generate(32, (i) => (i * 11 + 5) & 0xff);

/// What [_groupId] encodes to.
final String _groupHex =
    _groupId().map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('encodeWireRoutingDecl — accepts a circle routing', () {
    test('the payload is exactly {h, relays}, h as 64 lowercase hex', () {
      final payload = encodeWireRoutingDecl(
        nostrGroupId: _groupId(),
        relays: const <String>['ws://10.0.2.2:7789', 'wss://relay.test:443/x'],
      );
      // Exactly these two keys: the oracle refuses any other payload shape.
      expect(payload.keys.toSet(), <String>{'h', 'relays'});
      expect(payload['h'], _groupHex);
      expect(
        RegExp(r'^[0-9a-f]{64}$').hasMatch(payload['h']! as String),
        isTrue,
      );
      expect(
        payload['relays'],
        <String>['ws://10.0.2.2:7789', 'wss://relay.test:443/x'],
      );
    });

    test('the payload holds a copy, not the caller list', () {
      final relays = <String>['ws://127.0.0.1:7789'];
      final payload = encodeWireRoutingDecl(
        nostrGroupId: _groupId(),
        relays: relays,
      );
      relays.add('ws://127.0.0.1:7788');
      expect(payload['relays'], <String>['ws://127.0.0.1:7789']);
    });
  });

  group('encodeWireRoutingDecl — rejects what the oracle cannot use', () {
    void rejects(List<int> id, List<String> relays) => expect(
      () => encodeWireRoutingDecl(nostrGroupId: id, relays: relays),
      throwsA(isA<ArgumentError>()),
    );

    test('a group id one byte short or long', () {
      rejects(List<int>.filled(31, 1), const <String>['ws://h:7789']);
      rejects(List<int>.filled(33, 1), const <String>['ws://h:7789']);
    });

    test('a byte outside 0..255', () {
      rejects(_groupId()..[4] = 256, const <String>['ws://h:7789']);
      rejects(_groupId()..[0] = -1, const <String>['ws://h:7789']);
    });

    test('no relay at all', () {
      rejects(_groupId(), const <String>[]);
    });

    test('a relay without an explicit port, or not a websocket URL', () {
      for (final url in const <String>[
        'ws://10.0.2.2',
        'wss://relay.test/path',
        'http://10.0.2.2:7789',
        '10.0.2.2:7789',
        'ws://:7789',
        'ws://10.0.2.2:0',
        'ws://10.0.2.2:70000',
      ]) {
        rejects(_groupId(), <String>['ws://10.0.2.2:7789', url]);
      }
    });
  });

  group('encodeWireRoutingDecl — errors leak nothing (Security Rule 15)', () {
    test('a bad relay is named by position, never by URL or group id', () {
      const planted = 'ws://planted-host-7c1d.test';
      expect(
        () => encodeWireRoutingDecl(
          nostrGroupId: _groupId(),
          relays: const <String>['ws://10.0.2.2:7789', planted],
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'rendered error',
            allOf(
              contains('relay 1'),
              isNot(contains('planted-host')),
              isNot(contains('10.0.2.2')),
              isNot(contains(_groupHex.substring(0, 8))),
            ),
          ),
        ),
      );
    });

    test('a bad group id is named by length or position, never by value', () {
      final short = List<int>.filled(31, 0xde);
      final wide = _groupId()..[9] = 4242;
      for (final id in <List<int>>[short, wide]) {
        expect(
          () => encodeWireRoutingDecl(
            nostrGroupId: id,
            relays: const <String>['ws://10.0.2.2:7789'],
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'rendered error',
              allOf(
                isNot(contains('dede')),
                isNot(contains('4242')),
                isNot(contains(_groupHex.substring(0, 8))),
                isNot(contains('10.0.2.2')),
              ),
            ),
          ),
        );
      }
    });
  });

  test('the token prefix is the one the oracle parses', () {
    // Two spellings of one contract in two languages: a drift makes every
    // routing declaration a malformed sentinel, which the oracle reports as
    // UNUSABLE for the whole run.
    const prefix = 'HAVEN_WIRE_ROUTING:';
    final dart = File(
      'integration_test/e2e/_lib/test_relay.dart',
    ).readAsStringSync();
    final rust = File(
      '../tooling/e2e/local-relay/src/planes/cli.rs',
    ).readAsStringSync();
    expect(
      dart.contains("const String _routingTokenPrefix = '$prefix';"),
      isTrue,
    );
    expect(
      rust.contains(
        'pub const ROUTING_DECLARATION_PREFIX: &str = "$prefix";',
      ),
      isTrue,
    );
  });
}
