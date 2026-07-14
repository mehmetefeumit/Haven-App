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
    this.subscribeGate,
    this.unsubscribeGate,
    this.throwOnStop = false,
    this.throwOnStart = false,
    this.throwOnSubscribe = false,
    this.throwOnUnsubscribe = false,
  });

  /// When set, [stop] awaits this before completing, so a test can hold a
  /// full restart in-flight (suspended on `stop()`) while it drives
  /// `dispose()`.
  final Future<void>? stopGate;

  /// When set, [start] awaits this AFTER recording the call, so a test can hold
  /// a full restart suspended inside `start()` while a test drives `dispose()`.
  final Future<void>? startGate;

  /// When set, [subscribeCircle] awaits this AFTER recording the call, so a
  /// test can hold a delta apply suspended mid-loop while it drives
  /// `dispose()`.
  final Future<void>? subscribeGate;

  /// When set, [unsubscribeCircle] awaits this AFTER recording the call — the
  /// `unsubscribeCircle` counterpart to [subscribeGate].
  final Future<void>? unsubscribeGate;

  /// When true, [stop] throws an exception whose message embeds a fake group
  /// id (to prove the full-restart error path never leaks it).
  final bool throwOnStop;

  /// When true, [start] throws — models `engineFactory` REFUSING to open the
  /// circle manager (e.g. after a logout wipe, when there is no identity). The
  /// message embeds a fake group id to prove it is never logged.
  final bool throwOnStart;

  /// When true, [subscribeCircle] throws — models a delta op failing against a
  /// possibly-gone session, forcing the full-restart fallback. The message
  /// embeds a fake group id to prove it is never logged.
  final bool throwOnSubscribe;

  /// When true, [unsubscribeCircle] throws — the `unsubscribeCircle`
  /// counterpart to [throwOnSubscribe].
  final bool throwOnUnsubscribe;

  final List<_StartCall> startCalls = [];

  /// Every [subscribeCircle] call, in call order.
  final List<FfiGroupSpec> subscribeCalls = [];

  /// Every [unsubscribeCircle] call's `nostr_group_id`, in call order.
  final List<Uint8List> unsubscribeCalls = [];
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
  Future<void> subscribeCircle(FfiGroupSpec spec) async {
    subscribeCalls.add(spec);
    if (subscribeGate != null) await subscribeGate;
    if (throwOnSubscribe) {
      throw Exception('boom for nostr group ${'ab' * 16}');
    }
  }

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async {
    unsubscribeCalls.add(nostrGroupId);
    if (unsubscribeGate != null) await unsubscribeGate;
    if (throwOnUnsubscribe) {
      throw Exception('boom for nostr group ${'ab' * 16}');
    }
  }

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

/// The hex `nostr_group_id` of [bytes] — a test-local duplicate of the
/// resubscriber's private `_hex`, so `computeDelta` tests can build a
/// `running` map keyed the same way without reaching into resubscriber
/// internals.
String _hexOf(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The `computeDelta` "running" map for [circles], keyed by hex
/// `nostr_group_id` — mirrors what the resubscriber's constructor seeds
/// `_running` with from `initialGroups`.
Map<String, FfiGroupSpec> _runningMap(List<Circle> circles) => {
  for (final g in LiveSyncResubscriber.groupsForCircles(circles))
    _hexOf(g.nostrGroupId): g,
};

LiveSyncResubscriber _resub(
  _RecordingEngine engine,
  List<Circle> initial, {
  Duration debounce = const Duration(milliseconds: 500),
}) => LiveSyncResubscriber(
  engine: engine,
  inboxRelays: () async => const ['wss://inbox'],
  initialSignature: _sigOf(initial),
  initialGroups: LiveSyncResubscriber.groupsForCircles(initial),
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
  // computeDelta — pure diff of the running set against a fresh snapshot.
  // -------------------------------------------------------------------------
  group('LiveSyncResubscriber.computeDelta (pure)', () {
    test('an added circle appears only in added', () {
      final delta = LiveSyncResubscriber.computeDelta(
        _runningMap([_circle(tag: 1)]),
        LiveSyncResubscriber.groupsForCircles([
          _circle(tag: 1),
          _circle(tag: 2),
        ]),
      );
      expect(_tagsOf(delta.added), [2]);
      expect(delta.removed, isEmpty);
      expect(delta.relayChanged, isEmpty);
      expect(delta.isEmpty, isFalse);
    });

    test('a removed circle appears only in removed', () {
      final delta = LiveSyncResubscriber.computeDelta(
        _runningMap([_circle(tag: 1), _circle(tag: 2)]),
        LiveSyncResubscriber.groupsForCircles([_circle(tag: 1)]),
      );
      expect(delta.added, isEmpty);
      expect(delta.removed, hasLength(1));
      expect(delta.removed.single.first, 2);
      expect(delta.relayChanged, isEmpty);
      expect(delta.isEmpty, isFalse);
    });

    test(
      'a relay rotation on an existing circle appears only in relayChanged',
      () {
        final delta = LiveSyncResubscriber.computeDelta(
          _runningMap([_circle(tag: 1, relays: const ['wss://old'])]),
          LiveSyncResubscriber.groupsForCircles([
            _circle(tag: 1, relays: const ['wss://new']),
          ]),
        );
        expect(delta.added, isEmpty);
        expect(delta.removed, isEmpty);
        expect(_tagsOf(delta.relayChanged), [1]);
        expect(delta.isEmpty, isFalse);
      },
    );

    test('a roster/member change to an existing circle is NOT a delta op', () {
      // Same nostrGroupId + relays, only the member roster differs — matches
      // `decide`'s no-op semantics; computeDelta must agree.
      final delta = LiveSyncResubscriber.computeDelta(
        _runningMap([_circle(tag: 1)]),
        LiveSyncResubscriber.groupsForCircles([
          _circle(tag: 1, members: [_member('peer')]),
        ]),
      );
      expect(delta.isEmpty, isTrue);
    });

    test('an identical running and next set is empty (no ops)', () {
      final circles = [_circle(tag: 1), _circle(tag: 2)];
      final delta = LiveSyncResubscriber.computeDelta(
        _runningMap(circles),
        LiveSyncResubscriber.groupsForCircles(circles),
      );
      expect(delta.isEmpty, isTrue);
      expect(delta.added, isEmpty);
      expect(delta.removed, isEmpty);
      expect(delta.relayChanged, isEmpty);
    });

    test('nextRunning always reflects the full next set', () {
      final delta = LiveSyncResubscriber.computeDelta(
        _runningMap([_circle(tag: 1)]),
        LiveSyncResubscriber.groupsForCircles([
          _circle(tag: 1),
          _circle(tag: 2),
        ]),
      );
      expect(delta.nextRunning.keys, hasLength(2));
    });
  });

  // -------------------------------------------------------------------------
  // Orchestration — debounce + delta apply / full-restart fallback +
  // lifecycle, via a mock engine.
  // -------------------------------------------------------------------------
  group('LiveSyncResubscriber orchestration', () {
    test('adding an accepted circle subscribes only the new circle', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(
          engine.stopCalls,
          0,
          reason: 'an added circle is an incremental subscribeCircle, no '
              'stop/start',
        );
        expect(engine.startCalls, isEmpty);
        expect(engine.unsubscribeCalls, isEmpty);
        expect(engine.subscribeCalls, hasLength(1));
        expect(engine.subscribeCalls.single.nostrGroupId.first, 2);
        resub.dispose();
      });
    });

    test('leaving a circle unsubscribes only that circle', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        // circle 2 left → only circle 1 remains.
        final resub = _resub(engine, [_circle(tag: 1), _circle(tag: 2)])
          ..onCirclesChanged([_circle(tag: 1)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(engine.stopCalls, 0, reason: 'no stop/start for a plain leave');
        expect(engine.startCalls, isEmpty);
        expect(engine.subscribeCalls, isEmpty);
        expect(engine.unsubscribeCalls, hasLength(1));
        expect(engine.unsubscribeCalls.single.first, 2);
        resub.dispose();
      });
    });

    test('a relay rotation drops then re-subscribes just that circle', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine();
        final resub =
            _resub(engine, [_circle(tag: 1, relays: const ['wss://old'])])
              ..onCirclesChanged([
                _circle(tag: 1, relays: const ['wss://new']),
              ]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(engine.stopCalls, 0);
        expect(engine.startCalls, isEmpty);
        expect(engine.unsubscribeCalls, hasLength(1));
        expect(engine.unsubscribeCalls.single.first, 1);
        expect(engine.subscribeCalls, hasLength(1));
        expect(engine.subscribeCalls.single.relays, const ['wss://new']);
        resub.dispose();
      });
    });

    test('an unsubscribeCircle failure also falls back to a full restart', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine(throwOnUnsubscribe: true);
        // circle 2 left → only circle 1 remains.
        final resub = _resub(engine, [_circle(tag: 1), _circle(tag: 2)])
          ..onCirclesChanged([_circle(tag: 1)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(
          engine.unsubscribeCalls,
          hasLength(1),
          reason: 'the delta attempted unsubscribeCircle for the left circle',
        );
        expect(
          engine.stopCalls,
          1,
          reason: 'the delta failure fell back to a full restart',
        );
        expect(engine.startCalls, hasLength(1));
        expect(
          _tagsOf(engine.startCalls.single.groups),
          [1],
          reason: 'the full restart targets the full desired set',
        );
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
        expect(engine.subscribeCalls, isEmpty);
        expect(engine.unsubscribeCalls, isEmpty);
        resub.dispose();
      });
    });

    test('rapid successive changes coalesce into a single delta apply', () {
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
          engine.subscribeCalls,
          hasLength(2),
          reason: 'the burst coalesced to ONE delta apply (no storm)',
        );
        expect(
          _tagsOf(engine.subscribeCalls),
          [2, 3],
          reason: 'the single delta subscribes the final superset only',
        );
        expect(engine.stopCalls, 0);
        expect(engine.startCalls, isEmpty);
        resub.dispose();
      });
    });

    test(
      '_chain serializes two separately-debounced applies without '
      'interleaving',
      () {
        FakeAsync().run((async) {
          final gate = Completer<void>();
          final engine = _RecordingEngine(subscribeGate: gate.future);
          final resub = _resub(engine, [_circle(tag: 1)])
            ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
          // The first delta's timer fires, reaches subscribeCircle(2), and
          // suspends on the gate — its `_applyDelta` has not resolved yet.
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          expect(engine.subscribeCalls, hasLength(1));

          // A second, LATER change (its own debounce window — not a coalesced
          // burst) arrives while the first apply is still in flight.
          resub.onCirclesChanged([
            _circle(tag: 1),
            _circle(tag: 2),
            _circle(tag: 3),
          ]);
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          expect(
            engine.subscribeCalls,
            hasLength(1),
            reason:
                'the second apply is chained behind the still-gated first '
                'one — no interleaved engine call yet',
          );

          gate.complete();
          async.flushMicrotasks();

          // Both applies have now run, strictly in order: the first
          // completes (subscribing circle 2), then the second (computed
          // before the first resolved, so it re-applies circle 2 too — a
          // harmless, idempotent redundancy — before subscribing circle 3).
          expect(
            engine.subscribeCalls.map((s) => s.nostrGroupId.first).toList(),
            [2, 2, 3],
          );
          resub.dispose();
        });
      },
    );

    test('dispose mid-delta does not subscribe further circles after '
        'dispose', () {
      FakeAsync().run((async) {
        final gate = Completer<void>();
        final engine = _RecordingEngine(subscribeGate: gate.future);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([
            _circle(tag: 1),
            _circle(tag: 2),
            _circle(tag: 3),
          ]);
        // Fire the debounce → the delta reaches subscribeCircle for the first
        // added circle and suspends on the gate before the second.
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        expect(engine.subscribeCalls, hasLength(1));

        // Widget disposes mid-delta, THEN the gated call resolves.
        resub.dispose();
        gate.complete();
        async.flushMicrotasks();

        expect(
          engine.subscribeCalls,
          hasLength(1),
          reason:
              'no subscribe-after-dispose: the second added circle is '
              'skipped',
        );
        expect(engine.stopCalls, 0);
        expect(engine.startCalls, isEmpty);
      });
    });

    test(
      'dispose mid-delta does not unsubscribe further circles after '
      'dispose',
      () {
        FakeAsync().run((async) {
          final gate = Completer<void>();
          final engine = _RecordingEngine(unsubscribeGate: gate.future);
          // circles 2 and 3 both left → only circle 1 remains.
          final resub =
              _resub(engine, [
                _circle(tag: 1),
                _circle(tag: 2),
                _circle(tag: 3),
              ])..onCirclesChanged([_circle(tag: 1)]);
          // Fire the debounce → the delta reaches unsubscribeCircle for the
          // first removed circle and suspends on the gate before the second.
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          expect(engine.unsubscribeCalls, hasLength(1));

          // Widget disposes mid-delta, THEN the gated call resolves.
          resub.dispose();
          gate.complete();
          async.flushMicrotasks();

          expect(
            engine.unsubscribeCalls,
            hasLength(1),
            reason:
                'no unsubscribe-after-dispose: the second removed circle '
                'is skipped',
          );
          expect(engine.stopCalls, 0);
          expect(engine.startCalls, isEmpty);
        });
      },
    );

    test('dispose cancels a pending apply that has not fired yet', () {
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
        expect(engine.subscribeCalls, isEmpty);
        expect(engine.unsubscribeCalls, isEmpty);
      });
    });

    test('a reverted change (back to the running set) cancels the apply', () {
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
        expect(engine.subscribeCalls, isEmpty);
        expect(engine.unsubscribeCalls, isEmpty);
        resub.dispose();
      });
    });

    test('a delta-op failure falls back to a full restart', () {
      FakeAsync().run((async) {
        final engine = _RecordingEngine(throwOnSubscribe: true);
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();

        expect(
          engine.subscribeCalls,
          hasLength(1),
          reason: 'the delta attempted subscribeCircle for the new circle '
              'first',
        );
        expect(
          engine.stopCalls,
          1,
          reason: 'the delta failure fell back to a full restart',
        );
        expect(engine.startCalls, hasLength(1));
        expect(
          _tagsOf(engine.startCalls.single.groups),
          [1, 2],
          reason: 'the full restart targets the full desired set',
        );
        expect(engine.startCalls.single.inboxRelays, const ['wss://inbox']);

        // A later snapshot identical to the just-applied set is a no-op —
        // proves the running set adopted the full-restarted target.
        resub.onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(seconds: 5))
          ..flushMicrotasks();
        expect(
          engine.stopCalls,
          1,
          reason: 'no further restart — already at the adopted target',
        );
        expect(engine.startCalls, hasLength(1));
        resub.dispose();
      });
    });

    test(
      'engine already stopped → skips the delta attempt and full-restarts',
      () {
        FakeAsync().run((async) {
          final engine = _RecordingEngine();
          final resub = _resub(engine, [_circle(tag: 1)]);
          // Stop the engine BEFORE the circle change — mirrors the engine
          // being stopped by something else (e.g. between test scenarios)
          // while this resubscriber's own `_running` snapshot still reflects
          // the OLD (now stale) group set.
          engine._running = false;
          resub.onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();

          expect(
            engine.subscribeCalls,
            isEmpty,
            reason: 'isRunning==false must skip the doomed subscribeCircle '
                'attempt entirely',
          );
          expect(engine.unsubscribeCalls, isEmpty);
          expect(
            engine.startCalls,
            hasLength(1),
            reason: 'falls straight through to a full restart',
          );
          expect(
            _tagsOf(engine.startCalls.single.groups),
            [1, 2],
            reason: 'the full restart targets the full desired set',
          );
          resub.dispose();
        });
      },
    );

    test(
      'a delta then full-restart failure never leaks the raw error to logs',
      () {
        final logs = <String>[];
        final original = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          if (message != null) logs.add(message);
        };
        addTearDown(() => debugPrint = original);

        FakeAsync().run((async) {
          final engine = _RecordingEngine(
            throwOnSubscribe: true,
            throwOnStop: true,
          );
          final resub = _resub(engine, [_circle(tag: 1)])
            ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
          // Fire the apply so subscribeCircle throws (→ full restart), whose
          // own stop() then also throws.
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          resub.dispose();
        });

        final joined = logs.join('\n');
        expect(joined, contains('delta failed'));
        expect(joined, contains('full restart failed'));
        // Both thrown errors embed a fake group hex; only the runtimeType is
        // ever logged (Security Rule 8).
        expect(joined, isNot(contains('abababab')));
      },
    );

    test(
      'dispose mid-full-restart does not start after dispose',
      () {
        FakeAsync().run((async) {
          final stopGate = Completer<void>();
          final engine = _RecordingEngine(
            throwOnSubscribe: true,
            stopGate: stopGate.future,
          );
          final resub = _resub(engine, [_circle(tag: 1)])
            ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
          // Fire the debounced delta: subscribeCircle throws, the full
          // restart begins and suspends on stop()'s gate.
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          expect(
            engine.stopCalls,
            1,
            reason: 'the delta failure reached the full-restart stop()',
          );
          expect(
            engine.startCalls,
            isEmpty,
            reason: 'still awaiting the stop gate',
          );

          // Widget disposes mid-full-restart, THEN the stop resolves.
          resub.dispose();
          stopGate.complete();
          async.flushMicrotasks();

          expect(
            engine.startCalls,
            isEmpty,
            reason:
                'no start-after-dispose: the post-stop guard short-circuits',
          );
        });
      },
    );

    test(
      'dispose during a full-restart start() tears down the freshly started '
      'session',
      () {
        // A dispose that lands while the full restart's own start() is in
        // flight must stop that session so it is not orphaned past teardown.
        FakeAsync().run((async) {
          final startGate = Completer<void>();
          final engine = _RecordingEngine(
            throwOnSubscribe: true,
            startGate: startGate.future,
          );
          final resub = _resub(engine, [_circle(tag: 1)])
            ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
          // The delta fails, the full restart stops, then suspends inside
          // start().
          async
            ..elapse(const Duration(milliseconds: 500))
            ..flushMicrotasks();
          expect(
            engine.startCalls.length,
            1,
            reason: 'the full restart reached start()',
          );
          expect(
            engine.stopCalls,
            1,
            reason: 'stop() ran before the new start()',
          );

          // Dispose while start() is still suspended, then let it finish.
          resub.dispose();
          startGate.complete();
          async.flushMicrotasks();

          expect(
            engine.stopCalls,
            2,
            reason:
                'the session started after dispose is stopped, not orphaned',
          );
        });
      },
    );

    test('a throwing full-restart start() is caught and never leaks the '
        'group id', () {
      // Models `engineFactory` REFUSING (start throws) — e.g. a restart
      // racing a logout after the M10 wipe. The resubscriber must swallow it
      // (the next change retries) and log only the runtimeType.
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      FakeAsync().run((async) {
        final engine = _RecordingEngine(
          throwOnSubscribe: true,
          throwOnStart: true,
        );
        final resub = _resub(engine, [_circle(tag: 1)])
          ..onCirclesChanged([_circle(tag: 1), _circle(tag: 2)]);
        async
          ..elapse(const Duration(milliseconds: 500))
          ..flushMicrotasks();
        resub.dispose();
      });

      final joined = logs.join('\n');
      expect(joined, contains('full restart failed'));
      expect(joined, isNot(contains('abababab')));
    });
  });
}
