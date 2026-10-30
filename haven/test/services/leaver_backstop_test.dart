// The leaver backstop: each plane's wake carries every leave this device asked
// for on through the core's `resume_leave`, which alone decides when a leave
// ends — a peer's commit, the copy marked removed, or the day's bound from the
// intent (`haven-core/tests/leave_fanout_e2e.rs`
// `a_pending_leave_ends_at_its_bound_anchored_on_the_intent_time`, the leave's
// budget leg). What Dart promises: every circle is asked, the core says which
// have a leave at all, an ended leave is handed back for forgetting, a wait
// the core names is honoured, and nothing is ever asked twice in one wake.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/leaver_backstop.dart';

import '../helpers/fake_change_driver.dart';
import '../helpers/log_capture.dart';

void main() {
  const a = [1, 1, 1];
  const b = [2, 2, 2];

  ({LeaverBackstop backstop, FakeChangeDriver driver, _Roster manager})
  build({DateTime Function()? clock}) => (
    backstop: LeaverBackstop(clock: clock),
    driver: FakeChangeDriver(),
    manager: _Roster([a, b]),
  );

  test('a background plane asks every circle once, claiming no foreground',
      () async {
    final t = build();

    final carried = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
    );

    expect(carried.left, isEmpty, reason: 'no circle has a leave: none ended');
    expect(t.driver.calls, ['resumeLeave', 'resumeLeave']);
    expect(t.driver.groupIds, [a, b]);
    expect(t.driver.managers, everyElement(same(t.manager)));
    expect(t.driver.foregrounds, [false, false]);
  });

  test('a foreground plane claims the foreground, and a pause stops it at '
      'the next circle', () async {
    final t = build();
    var resumed = true;
    final driver = _OnCall(() => resumed = false);

    await t.backstop.carryOn(
      manager: t.manager,
      driver: driver,
      inFront: () => resumed,
    );

    expect(driver.groupIds, [a], reason: 'a paused process carried a leave on');
    expect(driver.foregrounds, [true]);
  });

  test('a leave refused until an admin steps down ends unmade: never asked '
      'for again, never handed back as left, and said with fixed text',
      () async {
    final capture = LogCapture.install();
    final t = build();
    t.driver.resumeLeaveOutcomes = {
      a.join(','): const LeaveOutcomeFfi(
        status: LeaveStatusFfi.adminMustStepDown,
      ),
    };

    final carried = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
      inFront: () => true,
    );

    expect(carried.left, isEmpty);
    expect(t.driver.calls, ['resumeLeave', 'resumeLeave']);
    capture
      ..assertContains('[Leave] carry-on ended unmade')
      ..assertNoNeedles([_hex(a), _hex(_nostrIdOf(a)), 'wss://circle.example']);
  });

  test('a leave that ended, or whose circle is gone, is handed back by its '
      'public id', () async {
    final t = build();
    t.driver.resumeLeaveOutcomes = {
      a.join(','): const LeaveOutcomeFfi(status: LeaveStatusFfi.completed),
      b.join(','): const LeaveOutcomeFfi(status: LeaveStatusFfi.circleNotFound),
    };

    final carried = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
      inFront: () => true,
    );

    expect(carried.left.map((c) => c.mlsGroupId), [a, b]);
    expect(carried.left.map((c) => c.nostrGroupId), [
      _nostrIdOf(a),
      _nostrIdOf(b),
    ]);
  });

  test('a standing leave is asked again at the next wake, never twice in one, '
      'and not before the wait the core named', () async {
    var now = DateTime.utc(2026, 10, 16, 12);
    final t = build(clock: () => now);
    t.driver.resumeLeaveOutcomes = {
      // "At the next call": the next wake, never a loop inside this one.
      a.join(','): LeaveOutcomeFfi(
        status: LeaveStatusFfi.pending,
        retryAfterMs: BigInt.zero,
      ),
      b.join(','): LeaveOutcomeFfi(
        status: LeaveStatusFfi.proposed,
        retryAfterMs: BigInt.from(30000),
      ),
    };
    Future<void> wake() => t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
      inFront: () => true,
    );

    await wake();
    expect(t.driver.groupIds, [a, b]);

    now = now.add(const Duration(seconds: 29));
    await wake();
    expect(
      t.driver.groupIds,
      [a, b, a],
      reason: 'b was asked again inside the 30 s its last answer named',
    );

    now = now.add(const Duration(seconds: 1));
    await wake();
    expect(t.driver.groupIds, [a, b, a, a, b]);
  });

  test('a carry-on past the waits asks a circle inside its wait: a group '
      'update may be the commit that ends its leave', () async {
    var now = DateTime.utc(2026, 10, 17, 12);
    final t = build(clock: () => now);
    t.driver.resumeLeaveOutcomes = {
      a.join(','): LeaveOutcomeFfi(
        status: LeaveStatusFfi.proposed,
        retryAfterMs: BigInt.from(60000),
      ),
    };
    await t.backstop.carryOn(manager: t.manager, driver: t.driver);
    now = now.add(const Duration(seconds: 10));

    await t.backstop.carryOn(manager: t.manager, driver: t.driver);
    expect(
      t.driver.groupIds,
      [a, b, b],
      reason: 'premise: a is inside its wait',
    );
    await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
      pastWaits: true,
    );

    expect(t.driver.groupIds, [a, b, b, a, b]);
  });

  test('a leave still standing says when it is next due: the soonest wait '
      'the core named, and whether one named none', () async {
    var now = DateTime.utc(2026, 10, 17, 12);
    final t = build(clock: () => now);
    t.driver.resumeLeaveOutcomes = {
      a.join(','): LeaveOutcomeFfi(
        status: LeaveStatusFfi.proposed,
        retryAfterMs: BigInt.from(60000),
      ),
      b.join(','): const LeaveOutcomeFfi(status: LeaveStatusFfi.pending),
    };

    final first = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
    );
    expect(first.namedWait, const Duration(seconds: 60));
    expect(first.unnamedStanding, isTrue);

    now = now.add(const Duration(seconds: 20));
    t.driver.resumeLeaveOutcomes = {};
    final later = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
    );
    expect(
      later.namedWait,
      const Duration(seconds: 40),
      reason: 'a circle skipped inside its wait still stands',
    );
    expect(later.unnamedStanding, isFalse);

    t.backstop.forget();
    final forgotten = await t.backstop.carryOn(
      manager: t.manager,
      driver: t.driver,
    );
    expect(forgotten.standing, isFalse, reason: 'a forgotten wait still held');
  });

  test('one failing circle costs the others nothing, and its log line names '
      'no circle', () async {
    final capture = LogCapture.install();
    final t = build();
    final driver = _FailingFor(a);
    t.driver.resumeLeaveOutcomes = {};
    driver.resumeLeaveOutcomes = {
      b.join(','): const LeaveOutcomeFfi(status: LeaveStatusFfi.completed),
    };

    final carried = await t.backstop.carryOn(
      manager: t.manager,
      driver: driver,
    );

    expect(carried.left.map((c) => c.mlsGroupId), [b]);
    expect(capture.joined, contains('[Leave] carry-on failed'));
    capture.assertNoNeedles([
      _hex(a),
      _hex(_nostrIdOf(a)),
      _FailingFor.planted,
      'wss://circle.example',
    ]);
  });

  test('an unreadable roster asks nothing and says so with a type alone',
      () async {
    final capture = LogCapture.install();
    final t = build();

    final carried = await t.backstop.carryOn(
      manager: _Roster.unreadable(),
      driver: t.driver,
      inFront: () => true,
    );

    expect(carried.left, isEmpty);
    expect(t.driver.calls, isEmpty);
    expect(capture.joined, contains('[Leave] carry-on: circles unreadable'));
    capture.assertNoNeedles([_Roster.planted]);
  });
}

List<int> _nostrIdOf(List<int> groupId) => [for (final x in groupId) x + 100];

String _hex(List<int> bytes) =>
    bytes.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// A driver whose `resumeLeave` throws for one circle, with an identifier in
/// the error a careless log line would print.
class _FailingFor extends FakeChangeDriver {
  _FailingFor(this.failing);

  final List<int> failing;

  static const planted = 'group 0xdeadbeefcafe at wss://circle.example';

  @override
  Future<LeaveOutcomeFfi> resumeLeave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) {
    if (mlsGroupId.join(',') == failing.join(',')) {
      return Future.error(StateError(planted));
    }
    return super.resumeLeave(
      circle: circle,
      mlsGroupId: mlsGroupId,
      foreground: foreground,
    );
  }
}

/// A driver that runs [onCall] inside each `resumeLeave`, before answering.
class _OnCall extends FakeChangeDriver {
  _OnCall(this.onCall);

  final void Function() onCall;

  @override
  Future<LeaveOutcomeFfi> resumeLeave({
    required CircleManagerFfi circle,
    required List<int> mlsGroupId,
    required bool foreground,
  }) {
    onCall();
    return super.resumeLeave(
      circle: circle,
      mlsGroupId: mlsGroupId,
      foreground: foreground,
    );
  }
}

/// A [CircleManagerFfi] serving a roster of circles, or failing to.
class _Roster implements CircleManagerFfi {
  _Roster(this.groupIds) : unreadable = false;

  _Roster.unreadable() : groupIds = const [], unreadable = true;

  final List<List<int>> groupIds;
  final bool unreadable;

  static const planted = 'store at /data/user/0/haven/circles.db';

  @override
  Future<List<CircleWithMembersFfi>> getVisibleCircles() async {
    if (unreadable) throw StateError(planted);
    return [
      for (final id in groupIds)
        CircleWithMembersFfi(
          circle: CircleFfi(
            mlsGroupId: Uint8List.fromList(id),
            nostrGroupId: Uint8List.fromList(_nostrIdOf(id)),
            displayName: 'Fixture',
            circleType: 'location_sharing',
            relays: const ['wss://circle.example'],
            createdAt: 0,
            updatedAt: 0,
          ),
          membershipStatus: 'accepted',
          members: const [],
          engineState: CircleEngineStateFfi.live,
        ),
    ];
  }

  @override
  void dispose() {}

  @override
  bool get isDisposed => false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unexpected call: ${invocation.memberName}');
}
