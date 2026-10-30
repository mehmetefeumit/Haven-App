// What `NostrRelayService.shutdown` closes. The logout relies on it: the next
// identity's first relay call must open a pool of its own, never ride the
// previous identity's sockets.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show
        CircleManagerFfi,
        EvolutionOutcomeFfi,
        PublishStatusFfi,
        RelayManagerFfi;
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart'
    show RelayServiceException;

class _Pool implements RelayManagerFfi {
  int shutdownCalls = 0;

  /// When set, [shutdown] waits for it: a disconnect still under way.
  Completer<void>? shutdownGate;

  @override
  Future<void> shutdown() async {
    shutdownCalls++;
    await shutdownGate?.future;
  }

  /// How many changes were driven through this pool.
  int driven = 0;

  @override
  Future<EvolutionOutcomeFfi> removeMembersDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required List<String> memberPubkeys,
    required bool foreground,
  }) async {
    driven++;
    return const EvolutionOutcomeFfi(
      status: PublishStatusFfi.confirmed,
      welcomesDelivered: 0,
      welcomesTotal: 0,
      reinviteOwed: false,
      replayed: [],
    );
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected relay call');
}

class _Circles implements CircleManagerFfi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected circle call');
}

void main() {
  test('the call after a shutdown opens a pool of its own', () async {
    final pools = [_Pool(), _Pool()];
    var opened = 0;
    final relay = NostrRelayService(openPool: () async => pools[opened++]);
    await relay.initialize();
    await relay.shutdown();
    expect(relay.poolOpenForTest, isFalse);

    await relay.initialize();
    expect(opened, 2, reason: 'the shut pool was handed out again');
    expect(pools.first.shutdownCalls, 1);
    expect(pools.last.shutdownCalls, 0);
  });

  test('a latched service hands out no pool, not even the one still open, '
      'and opens none', () async {
    // The Android service latches at its stop and shuts the pool only after
    // its drains: a step that slips past every stop read meets the latch.
    final pools = [_Pool(), _Pool()];
    var opened = 0;
    final relay = NostrRelayService(openPool: () async => pools[opened++]);
    await relay.initialize();

    relay.latch();
    await expectLater(
      relay.removeMembers(
        circle: _Circles(),
        mlsGroupId: const [1],
        memberPubkeys: const ['aa'],
        foreground: false,
      ),
      throwsA(isA<RelayServiceException>()),
    );

    expect(opened, 1, reason: 'a latched service opened a pool');
    expect(pools.map((p) => p.driven), [0, 0]);

    var unopened = 0;
    final neverOpened = NostrRelayService(
      openPool: () async {
        unopened++;
        return _Pool();
      },
    )..latch();
    await expectLater(
      neverOpened.initialize(),
      throwsA(isA<RelayServiceException>()),
    );
    expect(unopened, 0, reason: 'a latched service opened a pool');
  });

  test('a call waiting on an open the latch overtook is handed nothing, and '
      "the teardown's shutdown closes what that open produced", () async {
    final open = Completer<_Pool>();
    final pool = _Pool();
    final relay = NostrRelayService(openPool: () => open.future);
    final waiting = expectLater(
      relay.removeMembers(
        circle: _Circles(),
        mlsGroupId: const [1],
        memberPubkeys: const ['aa'],
        foreground: false,
      ),
      throwsA(isA<RelayServiceException>()),
    );
    await pumpEventQueue();

    relay.latch();
    open.complete(pool);
    await waiting;
    await relay.shutdown();

    expect(
      pool.driven,
      0,
      reason: 'the call rode a pool opened past the latch',
    );
    expect(pool.shutdownCalls, 1);
    expect(relay.poolOpenForTest, isFalse);
  });

  test('a pool being disconnected is never handed out', () async {
    final first = _Pool()..shutdownGate = Completer<void>();
    final pools = [first, _Pool()];
    var opened = 0;
    final relay = NostrRelayService(openPool: () async => pools[opened++]);
    await relay.initialize();

    final shutting = relay.shutdown();
    await pumpEventQueue();
    expect(relay.poolOpenForTest, isFalse);
    await relay.initialize();
    expect(
      opened,
      2,
      reason: 'a call during the disconnect was handed the pool going down',
    );
    first.shutdownGate!.complete();
    await shutting;
    expect(relay.poolOpenForTest, isTrue, reason: 'the new pool was dropped');
  });

  test('a call waiting on the open a shutdown also waited on is handed a '
      'pool that open did not produce', () async {
    // Both waited on one open. The shutdown forgot the pool that open made
    // as soon as it ran: the call used to read the forgotten field (a null
    // check failure) or ride the pool going down.
    final open = Completer<_Pool>();
    final pools = [_Pool(), _Pool()];
    var opened = 0;
    final relay = NostrRelayService(
      openPool: () {
        opened++;
        return opened == 1 ? open.future : Future.value(pools[1]);
      },
    );
    final opening = relay.initialize();
    final call = relay.removeMembers(
      circle: _Circles(),
      mlsGroupId: const [1],
      memberPubkeys: const ['aa'],
      foreground: false,
    );
    final shutting = relay.shutdown();

    open.complete(pools[0]);
    await opening;
    await shutting;
    await call;

    expect(pools[0].shutdownCalls, 1);
    expect(pools[0].driven, 0, reason: 'the call rode the pool shut under it');
    expect(pools[1].driven, 1);
  });

  test('a pool that fails to open fails its callers and raises nothing '
      'unhandled', () async {
    // A failed open used to complete a completer nobody listened to.
    final relay = NostrRelayService(
      openPool: () async => throw StateError('no bridge'),
    );
    await expectLater(relay.initialize(), throwsStateError);
    expect(relay.poolOpenForTest, isFalse);
  });

  test('a shutdown during an open shuts the pool that open produces',
      () async {
    final pool = _Pool();
    final opening = Completer<RelayManagerFfi>();
    final relay = NostrRelayService(openPool: () => opening.future);
    final initializing = relay.initialize();
    final shutting = relay.shutdown();
    opening.complete(pool);
    await initializing;
    await shutting;

    expect(
      pool.shutdownCalls,
      1,
      reason: "a pool opened across the shutdown would be the next call's",
    );
    expect(relay.poolOpenForTest, isFalse);
  });
}
