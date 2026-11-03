/// Host-side proof of the relay-plane store check the unproxied lanes run
/// (`integration_test/e2e/_lib/plane_store_check.dart`) and of the store dump
/// under it (`TestRelay.dumpStore`).
///
/// The lanes hold each relay's store to the roles the test gave it; a check
/// that passed a crossing, judged a truncated dump as complete, or printed an
/// identifier while failing would each be silent there. Each is pinned below
/// against a fake relay that answers one REQ from a fixed store.
///
/// Runs under plain `flutter test`: no Rust bridge, no relay, no device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/e2e/_lib/plane_store_check.dart';
import '../../integration_test/e2e/_lib/test_relay.dart';

/// A planted author; no part of it may reach a failure message.
final String _pk = 'a1b2c3d4' * 8;

/// A stored event; [n] makes its id distinctive and unique.
Map<String, Object> _event(
  int n,
  int kind, [
  List<List<String>> tags = const <List<String>>[],
]) => <String, Object>{
      'id': 'feed${n.toString().padLeft(60, '0')}',
      'pubkey': _pk,
      'kind': kind,
      'created_at': 1785886144,
      'tags': tags,
      'content': '',
      'sig': 'f' * 128,
    };

void main() {
  late _FakeStore store;
  late TestRelay relay;

  setUp(() async {
    store = await _FakeStore.start();
    relay = await TestRelay.connect(url: 'ws://127.0.0.1:${store.port}');
  });

  tearDown(() async {
    await relay.dispose();
    await store.stop();
  });

  Matcher failsNaming(List<Object> wanted) => throwsA(
    isA<TestFailure>().having(
      (e) => e.message ?? '',
      'failure message',
      allOf(<Matcher>[
        for (final w in wanted) contains(w.toString()),
        isNot(contains(_pk.substring(0, 8))),
        isNot(contains('feed0')),
        isNot(contains('127.0.0.1')),
      ]),
    ),
  );

  group('assertStoreWithinRoles', () {
    test('a store within its roles passes', () async {
      store.events.addAll(<Map<String, Object>>[
        _event(1, 30443),
        _event(2, 10002),
        _event(3, 5, <List<String>>[
          <String>['a', '30443:$_pk:slot'],
          <String>['k', '30443'],
        ]),
      ]);
      await assertStoreWithinRoles(
        relay,
        check: 'T',
        roles: <String>{'keypackage'},
      );
    });

    test('a kind outside the roles fails, naming roles and kind only',
        () async {
      store.events.addAll(<Map<String, Object>>[
        _event(1, 1059),
        _event(2, 445),
      ]);
      await expectLater(
        assertStoreWithinRoles(relay, check: 'T', roles: <String>{'inbox'}),
        failsNaming(<Object>['inbox', '[445]']),
      );
    });

    test('a key-package retraction on a profile relay is a crossing',
        () async {
      store.events.add(
        _event(1, 5, <List<String>>[
          <String>['a', '30443:$_pk:slot'],
          <String>['k', '30443'],
        ]),
      );
      await expectLater(
        assertStoreWithinRoles(relay, check: 'T', roles: <String>{'profile'}),
        failsNaming(<Object>['profile', '[5]']),
      );
    });

    test('a profile retraction on a profile relay passes', () async {
      store.events.addAll(<Map<String, Object>>[
        _event(1, 0),
        _event(2, 5, <List<String>>[
          <String>['e', 'feed${'0' * 60}'],
          <String>['a', '0:$_pk:'],
        ]),
      ]);
      await assertStoreWithinRoles(
        relay,
        check: 'T',
        roles: <String>{'profile'},
      );
    });

    test("a deletion is judged by its `e` targets' kinds too", () async {
      // The relay still holds a location the deletion's `e` names: on a
      // profile relay that is a crossing however its `a` reads.
      store.events.addAll(<Map<String, Object>>[
        _event(1, 445),
        _event(2, 5, <List<String>>[
          <String>['e', _event(1, 445)['id']! as String],
          <String>['a', '0:$_pk:'],
        ]),
      ]);
      final before = <String>{_event(1, 445)['id']! as String};
      await expectLater(
        assertStoreWithinRoles(
          relay,
          check: 'T',
          roles: <String>{'profile'},
          before: before,
        ),
        failsNaming(<Object>['profile', '[5]']),
      );
    });

    test('a deletion naming no kind is admitted nowhere', () async {
      store.events.add(
        _event(1, 5, <List<String>>[
          <String>['e', 'feed${'0' * 60}'],
        ]),
      );
      await expectLater(
        assertStoreWithinRoles(
          relay,
          check: 'T',
          roles: <String>{'keypackage'},
        ),
        failsNaming(<Object>['[5]']),
      );
    });

    test('no role: any new event fails', () async {
      store.events.add(_event(1, 445));
      await expectLater(
        assertStoreWithinRoles(relay, check: 'T', roles: <String>{}),
        failsNaming(<Object>['no role', '[445]']),
      );
    });

    test('events held before, and the harness own, are not judged', () async {
      store.events.add(_event(1, 445));
      final before = await storeIds(relay);
      store.events.add(_event(2, 0));
      await assertStoreWithinRoles(
        relay,
        check: 'T',
        roles: <String>{'inbox'},
        before: before,
        harnessIds: <String>{_event(2, 0)['id']! as String},
      );
    });

    test('an unknown role name is refused', () async {
      await expectLater(
        assertStoreWithinRoles(relay, check: 'T', roles: <String>{'inbx'}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('assertStoreLacksKinds', () {
    test('a forbidden kind fails, an absent one passes', () async {
      store.events.add(_event(1, 30443));
      await assertStoreLacksKinds(relay, check: 'R1', kinds: <int>{0});
      store.events.add(_event(2, 0));
      await expectLater(
        assertStoreLacksKinds(relay, check: 'R1', kinds: <int>{0}),
        failsNaming(<Object>['R1', '[0]']),
      );
    });
  });

  group('TestRelay.dumpStore', () {
    test('asks once, with the limit and nothing else', () async {
      await relay.dumpStore();
      expect(store.filters, <Object?>[
        <String, Object?>{'limit': kDumpStoreLimit},
      ]);
    });

    test('below the limit the dump is the whole store', () async {
      for (var i = 0; i < kDumpStoreLimit - 1; i++) {
        store.events.add(_event(i, 1059));
      }
      expect(await relay.dumpStore(), hasLength(kDumpStoreLimit - 1));
    });

    test('an answer of exactly the limit is refused as maybe truncated',
        () async {
      for (var i = 0; i < kDumpStoreLimit; i++) {
        store.events.add(_event(i, 1059));
      }
      await expectLater(relay.dumpStore(), _refused('whole limit'));
    });

    test('CLOSED is a refusal, not an empty store', () async {
      store.answer = _Answer.closed;
      await expectLater(relay.dumpStore(), _refused('CLOSED'));
    });

    test('no EOSE is not an empty store', () async {
      store.answer = _Answer.silent;
      await expectLater(
        relay.dumpStore(timeout: const Duration(milliseconds: 200)),
        _refused('no EOSE'),
      );
    });
  });
}

/// A [StateError] naming why the dump was refused.
Matcher _refused(String why) => throwsA(
  isA<StateError>().having((e) => e.message, 'message', contains(why)),
);

enum _Answer { stored, closed, silent }

/// A relay with a fixed store: answers each REQ with every stored event and
/// `EOSE` (or `CLOSED`, or nothing).
class _FakeStore {
  _FakeStore._(this._server) {
    unawaited(_serve());
  }

  static Future<_FakeStore> start() async =>
      _FakeStore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<Map<String, Object>> events = <Map<String, Object>>[];
  final List<Object?> filters = <Object?>[];
  _Answer answer = _Answer.stored;

  int get port => _server.port;

  Future<void> _serve() async {
    await for (final request in _server) {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((dynamic data) {
        if (data is! String) return;
        final dynamic frame = jsonDecode(data);
        if (frame is! List || frame.length < 3 || frame.first != 'REQ') return;
        final sub = frame[1];
        filters.add(frame[2]);
        switch (answer) {
          case _Answer.stored:
            for (final e in events) {
              socket.add(jsonEncode(<Object?>['EVENT', sub, e]));
            }
            socket.add(jsonEncode(<Object?>['EOSE', sub]));
          case _Answer.closed:
            socket.add(jsonEncode(<Object?>['CLOSED', sub, 'error: no']));
          case _Answer.silent:
            break;
        }
      }, onError: (Object _) {}, cancelOnError: false);
    }
  }

  Future<void> stop() => _server.close(force: true);
}
