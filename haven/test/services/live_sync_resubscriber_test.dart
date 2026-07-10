import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart';
import 'package:haven/src/services/subscription_service.dart';

// ---------------------------------------------------------------------------
// Test doubles + helpers
// ---------------------------------------------------------------------------

/// One recorded [SubscriptionService.start] call.
class _StartCall {
  _StartCall(this.groups, this.inboxRelays);
  final List<FfiGroupSpec> groups;
  final List<String> inboxRelays;
}

/// A [SubscriptionService] that records start/stop calls + their group args.
///
/// Constructed "already started" (mirrors how `MapShell._startLiveSync` builds
/// the re-subscriber AFTER the initial `start()`). Only the 4 abstract members
/// are implemented — the engine internals are never exercised here.
class _RecordingEngine implements SubscriptionService {
  _RecordingEngine({
    this.stopGate,
    this.startGate,
    this.throwOnStop = false,
    this.throwOnStart = false,
  });

  /// When set, [stop] awaits this before completing, so a test can hold a
  /// restart in-flight (suspended on `stop()`) while it drives `dispose()`.
  final Future<void>? stopGate;

  /// When set, [start] awaits this AFTER recording the call, so a test can hold
  /// a restart suspended inside `start()` while a test drives `dispose()`.
  final Future<void>? startGate;

  /// When true, [stop] throws an exception whose message embeds a fake group
  /// id (to prove the re-subscribe error path never leaks it).
  final bool throwOnStop;

  /// When true, [start] throws — models `engineFactory` REFUSING to open the
  /// circle manager (e.g. after a logout wipe, when there is no identity). The
  /// message embeds a fake group id to prove it is never logged.
  final bool throwOnStart;

  final List<_StartCall> startCalls = [];
  int stopCalls = 0;
  bool _running = true;

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async {
    startCalls.add(_StartCall(groups, inboxRelays));
    if (startGate != null) await startGate;
    if (throwOnStart) {
      throw Exception('boom for nostr group ${'ab' * 16}');
    }
    _running = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _running = false;
    if (throwOnStop) {
      throw Exception('boom for nostr group ${'ab' * 16}');
    }
    if (stopGate != null) await stopGate;
  }

  @override
  Future<void> resumeAfterBackground() async {}

  @override
  bool get isRunning => _running;
}

CircleMember _member(String pubkey) => CircleMember(
  pubkey: pubkey,
  npub: 'npub1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq',
  isAdmin: false,
  status: MembershipStatus.accepted,
);

/// Builds a circle with a deterministic [tag]-derived `nostrGroupId`
/// (`List.filled(32, tag)`) so `groups.first.nostrGroupId.first == tag`.
Circle _circle({
  required int tag,
  MembershipStatus status = MembershipStatus.accepted,
  List<String> relays = const ['wss://relay.test'],
  List<CircleMember> members = const [],
}) => Circle(
  mlsGroupId: [tag, tag, tag],
  nostrGroupId: List<int>.filled(32, tag),
  displayName: 'Circle $tag',
  circleType: CircleType.locationSharing,
  relays: relays,
  membershipStatus: status,
  members: members,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

/// The sorted per-group tags of a started group set (each group's tag is its
/// `nostrGroupId.first`), for order-independent assertions.
List<int> _tagsOf(List<FfiGroupSpec> groups) =>
    groups.map((g) => g.nostrGroupId.first).toList()..sort();

/// The running signature the engine would have been started with for [circles].
String _sigOf(List<Circle> circles) => LiveSyncResubscriber.signatureForGroups(
  LiveSyncResubscriber.groupsForCircles(circles),
);

LiveSyncResubscriber _resub(
  _RecordingEngine engine,
  List<Circle> initial, {
  Duration debounce = const Duration(milliseconds: 500),
}) => LiveSyncResubscriber(
  engine: engine,
  inboxRelays: () async => const ['wss://inbox'],
  initialSignature: _sigOf(initial),
  debounce: debounce,
);

void main() {
  // -------------------------------------------------------------------------
  // Pure decision seam — provable WITHOUT the compile-time flag.
  // -------------------------------------------------------------------------
  group('LiveSyncResubscriber.decide (pure)', () {
    test('a null running signature is treated as changed', () {
      final d = LiveSyncResubscriber.decide(
        circles: [_circle(tag: 1)],
        runningSignature: null,
      );
      expect(d.changed, isTrue);
      expect(_tagsOf(d.groups), [1]);
    });

    test('the same set in any order is NOT a change (order-independent)', () {
      final running = _sigOf([_circle(tag: 1), _circle(tag: 2)]);
      final d = LiveSyncResubscriber.decide(
        circles: [_circle(tag: 2), _circle(tag: 1)],
        runningSignature: running,
      );
      expect(d.changed, isFalse);
    });

    test('adding an accepted circle is a change with the superset groups', () {
      final d = LiveSyncResubscriber.decide(
        circles: [_circle(tag: 1), _circle(tag: 2)],
        runningSignature: _sigOf([_circle(tag: 1)]),
      );
      expect(d.changed, isTrue);
      expect(_tagsOf(d.groups), [1, 2]);
    });

    test('a pending→accepted transition (accept invitation) is a change', () {
      // Circle 2 was pending (not subscribed); accepting it enters the set.
      final running = _sigOf([
        _circle(tag: 1),
        _circle(tag: 2, status: MembershipStatus.pending),
      ]);
      final d = LiveSyncResubscriber.decide(
        circles: [_circle(tag: 1), _circle(tag: 2)],
        runningSignature: running,
      );
      expect(d.changed, isTrue);
      expect(_tagsOf(d.groups), [1, 2]);
    });

    test('pending / declined circles are excluded from the group set', () {
      final groups = LiveSyncResubscriber.groupsForCircles([
        _circle(tag: 1),
        _circle(tag: 2, status: MembershipStatus.pending),
        _circle(tag: 3, status: MembershipStatus.declined),
      ]);
      expect(_tagsOf(groups), [1]);
    });

    test('a relay rotation on an existing circle is a change', () {
      final running = _sigOf([
        _circle(tag: 1, relays: const ['wss://old']),
      ]);
      final d = LiveSyncResubscriber.decide(
        circles: [_circle(tag: 1, relays: const ['wss://new'])],
        runningSignature: running,
      );
      expect(d.changed, isTrue);
    });

    test('a roster/member change to an existing circle is NOT a change', () {
      final running = _sigOf([_circle(tag: 1)]);
      final d = LiveSyncResubscriber.decide(
        // Same nostrGroupId + relays, only the member roster differs.
        circles: [
          _circle(tag: 1, members: [_member('peer')]),
        ],
        runningSignature: running,
      );
      expect(d.changed, isFalse);
    });

    test('leaving the last circle (→ empty set) is a change', () {
      final d = LiveSyncResubscriber.decide(
        circles: const [],
        runningSignature: _sigOf([_circle(tag: 1)]),
      );
      expect(d.changed, isTrue);
      expect(d.groups, isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // Orchestration — debounce + stop/start + lifecycle, via a mock engine.
  // -------------------------------------------------------------------------
  group('LiveSyncResubscriber orchestration', () {
    test('adding an accepted circle restarts with the new group', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(engine.stopCalls, 1, reason: 'stop+start interim');
        expect(engine.startCalls, hasLength(1));
        expect(
          _tagsOf(engine.startCalls.single.groups),
          [1, 2],
          reason: 'restarts with the superset including the new circle',
        );
        expect(engine.startCalls.single.inboxRelays, const ['wss://inbox']);
        resub.dispose();
      });
    });

    test('leaving a circle restarts the engine without it', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        // circle 2 left → only circle 1 remains.
        final resub = _resub(engine, [_circle(tag: 1), _circle(tag: 2)])
          ..onCirclesChanged([_circle(tag: 1)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(engine.startCalls, hasLength(1));
        expect(_tagsOf(engine.startCalls.single.groups), [1]);
        resub.dispose();
      });
    });

    test('an unrelated rebuild with the same group set does NOT restart', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        // Same nostrGroupId + relays — only a roster change. No restart.
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([
            _circle(tag: 1, members: [_member('peer')]),
          ]);
        async
          ..elapse(const Duration(seconds: 5))
          ..flushMicrotasks();

        expect(engine.stopCalls, 0);
        expect(engine.startCalls, isEmpty);
        resub.dispose();
      });
    });

    test('rapid successive changes coalesce into a single restart', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        // Two changes inside the debounce window (e.g. accepting two invites
        // in quick succession, or circlesProvider emitting twice).
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async.elapse(const Duration(milliseconds: 100));
        resub.onCirclesChanged([
          _circle(tag: 1),
          _circle(tag: 2),
          _circle(tag: 3),
        ]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(
          engine.startCalls,
          hasLength(1),
          reason: 'the burst coalesced to ONE restart (no storm)',
        );
        expect(engine.stopCalls, 1);
        expect(
          _tagsOf(engine.startCalls.single.groups),
          [1, 2, 3],
          reason: 'restarts once with the final superset',
        );
        resub.dispose();
      });
    });

    test('dispose mid-restart does not start after dispose', () {
      FakeAsync().run((async) {
        final gate = Completer<void>();
        final engine = _RecordingEngine(stopGate: gate.future);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        // Fire the debounce → _restart begins and suspends on stop()'s gate.
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        expect(engine.stopCalls, 1, reason: 'restart reached stop()');
        expect(engine.startCalls, isEmpty, reason: 'still awaiting stop gate');

        // Widget disposes mid-restart, THEN the stop resolves.
        resub.dispose();
        gate.complete();
        async.flushMicrotasks();

        expect(
          engine.startCalls,
          isEmpty,
          reason: 'no start-after-dispose: the post-stop guard short-circuits',
        );
      });
    });

    test('dispose cancels a pending restart that has not fired yet', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        // Dispose BEFORE the debounce elapses — the timer must be cancelled.
        _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)])
          ..dispose();
        async
          ..elapse(const Duration(seconds: 5))
          ..flushMicrotasks();

        expect(engine.stopCalls, 0);
        expect(engine.startCalls, isEmpty);
      });
    });

    test('a reverted change (back to the running set) cancels the restart', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]); // arm
        async.elapse(const Duration(milliseconds: 100));
        resub.onCirclesChanged([_circle(tag: 1)]); // revert before it fires
        async
          ..elapse(const Duration(seconds: 5))
          ..flushMicrotasks();

        expect(engine.stopCalls, 0, reason: 'net set never changed');
        expect(engine.startCalls, isEmpty);
        resub.dispose();
      });
    });

    test('a re-subscribe failure never leaks the raw error to logs', () {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      FakeAsync().run((async) {
        final engine = _RecordingEngine(throwOnStop: true);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        // Fire the restart so stop() throws and the error path logs.
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        resub.dispose();
      });

      final joined = logs.join('\n');
      expect(joined, contains('re-subscribe failed'));
      // stop() threw with a fake group hex in its message; only the
      // runtimeType is logged (Security Rule 8).
      expect(joined, isNot(contains('abababab')));
    });

    test('dispose during start() tears down the freshly started session', () {
      // Guard 3 (live_sync_resubscriber.dart): a dispose that lands while the
      // new session's start() is in flight must stop that session so it is not
      // orphaned past teardown.
      FakeAsync().run((async) {
        final startGate = Completer<void>();
        final engine = _RecordingEngine(startGate: startGate.future);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        // Fire the debounced restart: it stops, then suspends inside start().
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        expect(engine.startCalls.length, 1, reason: 'restart reached start()');
        expect(engine.stopCalls, 1, reason: 'stop() before the new start()');

        // Dispose while start() is still suspended, then let start() finish.
        resub.dispose();
        startGate.complete();
        async.flushMicrotasks();

        expect(
          engine.stopCalls,
          2,
          reason: 'the session started after dispose is stopped, not orphaned',
        );
      });
    });

    test('a throwing start() is caught and never leaks the group id', () {
      // Models `engineFactory` REFUSING (start throws) — e.g. a restart racing
      // a logout after the M10 wipe. The resubscriber must swallow it (the next
      // change retries) and log only the runtimeType.
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      FakeAsync().run((async) {
        final engine = _RecordingEngine(throwOnStart: true);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        resub.dispose();
      });

      final joined = logs.join('\n');
      expect(joined, contains('re-subscribe failed'));
      expect(joined, isNot(contains('abababab')));
    });
  });
}
