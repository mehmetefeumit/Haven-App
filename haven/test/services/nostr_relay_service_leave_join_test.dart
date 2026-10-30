// One leave per circle at a time in an isolate: `NostrRelayService` is the
// one `CircleChangeDriver` every plane uses, so a press and a carry-on, or two
// of either, landing together are joined here. That the core makes one intent
// and one proposal for calls that do race is Rust's
// (`haven-core/tests/leave_fanout_e2e.rs`
// `racing_leave_calls_make_one_intent_and_one_proposal`).
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_relay_service.dart';

/// A pool whose leave entries park until their gate is completed.
class _Pool implements RelayManagerFfi {
  final List<String> calls = [];
  final List<Completer<LeaveOutcomeFfi>> gates = [];

  Future<LeaveOutcomeFfi> _parked(String call) {
    calls.add(call);
    final gate = Completer<LeaveOutcomeFfi>();
    gates.add(gate);
    return gate.future;
  }

  @override
  Future<LeaveOutcomeFfi> leaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _parked('leave');

  @override
  Future<LeaveOutcomeFfi> resumeLeaveDriven({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) => _parked('resumeLeave');

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

class _Manager implements CircleManagerFfi {
  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}

const _proposed = LeaveOutcomeFfi(status: LeaveStatusFfi.proposed);
const _a = [1, 1];
const _b = [2, 2];

void main() {
  late _Pool pool;
  late NostrRelayService service;
  final manager = _Manager();

  setUp(() {
    pool = _Pool();
    service = NostrRelayService(openPool: () async => pool);
  });

  Future<LeaveOutcomeFfi> press(List<int> group) =>
      service.leave(circle: manager, mlsGroupId: group, foreground: true);
  Future<LeaveOutcomeFfi> carryOn(List<int> group) =>
      service.resumeLeave(circle: manager, mlsGroupId: group, foreground: true);

  test('a leave asked for twice at once is one leave', () async {
    final first = press(_a);
    final second = press(_a);
    await pumpEventQueue();
    expect(pool.calls, ['leave']);

    pool.gates.single.complete(_proposed);

    expect(await first, _proposed);
    expect(await second, _proposed);
    expect(pool.calls, ['leave'], reason: 'the second press asked again');
  });

  test('a carry-on landing beside a press joins it', () async {
    final pressed = press(_a);
    final carried = carryOn(_a);
    await pumpEventQueue();
    pool.gates.single.complete(_proposed);

    expect(await carried, _proposed);
    await pressed;
    expect(pool.calls, ['leave']);
  });

  test('two carry-ons at once are one', () async {
    final first = carryOn(_a);
    final second = carryOn(_a);
    await pumpEventQueue();
    pool.gates.single.complete(_proposed);

    await Future.wait([first, second]);
    expect(pool.calls, ['resumeLeave']);
  });

  test('a press landing beside a carry-on runs once that carry-on has ended',
      () async {
    final carried = carryOn(_a);
    final pressed = press(_a);
    await pumpEventQueue();
    expect(pool.calls, ['resumeLeave'], reason: 'the press ran beside it');

    pool.gates.single.complete(
      const LeaveOutcomeFfi(status: LeaveStatusFfi.notLeaving),
    );
    await carried;
    await pumpEventQueue();
    expect(pool.calls, ['resumeLeave', 'leave']);

    pool.gates.last.complete(_proposed);
    expect(await pressed, _proposed);
  });

  test('another circle is not joined, and a finished leave is asked again',
      () async {
    final a = press(_a);
    final b = press(_b);
    await pumpEventQueue();
    expect(pool.calls, ['leave', 'leave']);
    for (final gate in pool.gates) {
      gate.complete(_proposed);
    }
    await Future.wait([a, b]);

    final again = press(_a);
    await pumpEventQueue();
    expect(pool.calls, ['leave', 'leave', 'leave']);
    pool.gates.last.complete(_proposed);
    await again;
  });
}
