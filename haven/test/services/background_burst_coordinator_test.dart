/// Tests for [BackgroundBurstCoordinator] — the iOS background burst (P4).
///
/// Every property here is about ORDER or about a FAILURE path, which is why
/// the coordinator takes injected collaborators at all: none of this is
/// observable from the outside of a real burst, and all of it is silent when
/// it breaks. A burst that skipped its pause would leave the engine live with
/// standing REQs for the whole background window — no error, no dropped
/// location, just the battery drain the phase exists to remove.
library;

import 'dart:async';
import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart'
    show kLocationPublishMaxInterval;
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show kPublishLinkTimeout;
import 'package:haven/src/rust/api.dart'
    show BacklogOutcomeFfi, FfiGroupSpec;
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

// ---------------------------------------------------------------------------
// Fakes — all writing into ONE ordered log, because order is the subject
// ---------------------------------------------------------------------------

/// A [SubscriptionService] that records the burst lifecycle calls and can be
/// made to fail or stall any of them.
class _RecordingEngine implements SubscriptionService {
  _RecordingEngine(this.log);

  final List<String> log;

  /// Fails [openBackgroundBurst], the way the real wrapper does (it THROWS —
  /// a burst open has no redundancy, so it is never swallowed for the caller).
  bool throwOnOpen = false;

  /// Throws from [waitBacklogSettled]. The real service documents that it
  /// never does; this proves the burst still pauses if that ever changes.
  bool throwOnBacklog = false;

  /// Throws from [settleBeforePause] — the link immediately before the pause.
  /// If a throw here skipped the pause, the sockets would stay open.
  bool throwOnSettle = false;

  /// Throws from [pauseSubscriptions] — the link between the settle and the
  /// publish pool's shutdown. The real one throws on `NoSession` (a logout
  /// that raced the burst).
  bool throwOnPause = false;

  BacklogOutcomeFfi backlogOutcome = BacklogOutcomeFfi.settled;

  /// Held open to suspend the burst inside its open.
  Completer<void>? openGate;

  /// Held open to suspend the burst inside its backlog wait.
  Completer<void>? backlogGate;

  /// Held open to suspend the burst inside its settle, i.e. its teardown.
  Completer<void>? settleGate;

  /// Held open to suspend the burst inside its pause — the link after which
  /// the only thing left to protect is the publish pool.
  Completer<void>? pauseGate;

  int opens = 0;
  int settles = 0;
  int pauses = 0;
  bool _paused = false;

  @override
  Future<void> openBackgroundBurst() async {
    opens++;
    log.add('open');
    // Faithful to the engine: `paused` is cleared BEFORE anything touches a
    // socket, because every gate reads it and a burst that connected while
    // still flagged paused would have its own repairs refuse to act.
    _paused = false;
    if (openGate != null) await openGate!.future;
    if (throwOnOpen) {
      // …and RESTORED on every failure exit. The dominant one (a bucket no
      // relay accepted) also sweeps the registrations this open made, drains
      // the publish gauge and terminates every relay; the early shutdown exit
      // restores the flag and leaves the radio alone. Either way a failed open
      // leaves a session that READS paused — modelling it as un-paused would
      // encode behaviour the engine has not had since that fix, and let a
      // caller that relied on it pass here and fail in the field.
      _paused = true;
      throw const SubscriptionServiceException('failed to open burst');
    }
  }

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async {
    log.add('backlog');
    if (backlogGate != null) await backlogGate!.future;
    if (throwOnBacklog) throw StateError('backlog boom');
    return backlogOutcome;
  }

  @override
  Future<void> settleBeforePause() async {
    settles++;
    log.add('settle');
    if (settleGate != null) await settleGate!.future;
    if (throwOnSettle) throw StateError('settle boom');
  }

  @override
  Future<void> pauseSubscriptions() async {
    // The engine raises the flag as its FIRST statement — before it drops the
    // REQs, the router drain, the publish-drain wait and the disconnect — so
    // it reads true while all of those are still running or timing out.
    _paused = true;
    pauses++;
    log.add('pause');
    if (pauseGate != null) await pauseGate!.future;
    if (throwOnPause) throw StateError('pause boom');
  }

  @override
  bool get isPaused => _paused;

  @override
  bool get isRunning => true;

  @override
  Future<void> resumeAfterBackground() async =>
      throw UnimplementedError('a burst must never re-anchor as a foreground '
          'resume: that entry point always carries the inbox REQ');

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async => throw UnimplementedError('not reachable from a burst');

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async =>
      throw UnimplementedError('not reachable from a burst');

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async =>
      throw UnimplementedError('not reachable from a burst');

  @override
  Future<LiveSyncStopOutcome> stop() async =>
      throw UnimplementedError('not reachable from a burst');
}

/// A [BurstPublisher] that records which circles it published and how many
/// GPS windows it was asked for.
class _RecordingPublisher implements BurstPublisher {
  _RecordingPublisher(this.log);

  final List<String> log;

  /// Circle display names, in publish order.
  final List<String> published = [];

  /// One entry per [openBurstPublishWindow] call: the circles it was opened
  /// for.
  final List<List<String>> windows = [];

  /// The scheduler's eligible roster, by circle key. A tick only ever happens
  /// for a circle in it (the scheduler arms no timer for anything else), so
  /// the harness's `tick` registers here; removing an entry is how a circle
  /// gets blocked / left / orphaned mid-burst.
  final Map<String, Circle> roster = {};

  /// When true the window refuses (no identity / no disclosure / no fix).
  bool refuseWindow = false;

  /// When true [publishInBurst] throws — the real implementation never does,
  /// so this stands in for any future publisher that might.
  bool throwOnPublish = false;

  /// Runs while a publish is in flight, so a test can drive a tick that lands
  /// mid-burst.
  Future<void> Function()? duringPublish;

  /// Held open to suspend the burst inside its shared publish window — the
  /// seconds an identity read, a disclosure read and a one-shot GPS fix take,
  /// which is long enough for another circle's tick to land inside it.
  Completer<void>? windowGate;

  @override
  Circle? eligibleCircle(String circleKey) => roster[circleKey];

  @override
  Future<BurstFix?> openBurstPublishWindow(Iterable<Circle> circles) async {
    windows.add(circles.map((c) => c.displayName).toList());
    log.add('window');
    if (windowGate != null) await windowGate!.future;
    if (refuseWindow) return null;
    return BurstFix(
      senderPubkeyHex: 'ab' * 32,
      latitude: 1.5,
      longitude: 2.5,
    );
  }

  @override
  Future<void> publishInBurst(Circle circle, BurstFix fix) async {
    published.add(circle.displayName);
    log.add('publish:${circle.displayName}');
    if (duringPublish != null) {
      final hook = duringPublish;
      duringPublish = null;
      await hook!();
    }
    if (throwOnPublish) throw StateError('publish boom');
  }
}

/// A [BurstMaintenance] that records the folds and the instants they saw.
class _RecordingMaintenance implements BurstMaintenance {
  _RecordingMaintenance(this.log);

  final List<String> log;
  final List<DateTime> keyPackageAt = [];
  final List<DateTime> relayListAt = [];

  /// When true the KeyPackage fold throws — a maintenance failure must not
  /// take the burst's teardown with it.
  bool throwOnKeyPackage = false;

  /// Runs inside the fold, i.e. AFTER the burst's publish pass has closed.
  Future<void> Function()? duringFold;

  @override
  Future<void> runKeyPackageIfDue(DateTime now) async {
    keyPackageAt.add(now);
    log.add('kp');
    if (duringFold != null) {
      final hook = duringFold;
      duringFold = null;
      await hook!();
    }
    if (throwOnKeyPackage) throw StateError('kp boom');
  }

  @override
  Future<void> runRelayListIfDue(DateTime now) async {
    relayListAt.add(now);
    log.add('relayList');
  }
}

/// The commit-critical publishes the SHARED publish pool carries for someone
/// else — on iOS, the motion trigger's deferred-send ladder, which the burst
/// neither started nor awaits.
///
/// Models the field shape the drain's contract asks for: non-null while the
/// ladder is between `publishEvent` and `confirmPublished`, null the instant
/// it reaches its own conclusion — the `finally` the foreground service's
/// `_inFlightCommitCritical` already has.
class _PublishPoolWork {
  /// How many times the coordinator read the field.
  int reads = 0;

  Future<void>? _current;

  /// Starts one ladder and returns the handle that ends it.
  Completer<void> start() {
    final work = Completer<void>();
    _current = work.future;
    work.future
        .whenComplete(() {
          // Only if it is still the current one: a later ladder that started
          // while this one was in flight owns the field now.
          if (identical(_current, work.future)) _current = null;
        })
        .ignore();
    return work;
  }

  /// The read the coordinator is given.
  Future<void>? read() {
    reads++;
    return _current;
  }
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _Env {
  _Env({
    required this.log,
    required this.engine,
    required this.publisher,
    required this.maintenance,
    required this.coordinator,
    required this.shutdowns,
    required this.openOutcomes,
  });

  final List<String> log;
  final _RecordingEngine engine;
  final _RecordingPublisher publisher;
  final _RecordingMaintenance maintenance;
  final BackgroundBurstCoordinator coordinator;

  /// Mutable single-element counter for publish-pool shutdowns.
  final List<int> shutdowns;

  /// One entry per burst OPEN: the consecutive-failure count it reported.
  final List<int> openOutcomes;

  int get shutdownCount => shutdowns.first;
}

Circle _circle(String name, int id) => TestCircleFactory.createCircle(
  mlsGroupId: [id],
  nostrGroupId: [id, id],
  displayName: name,
);

void main() {
  /// Builds a coordinator over recording fakes.
  ///
  /// The stagger is neutralised by default ([PublishStagger.none]) because
  /// order, not timing, is what almost every test here is about; the one test
  /// whose subject IS the stagger builds its own.
  _Env build({
    bool Function()? burstEnabled,
    bool Function()? foregrounded,
    Future<void>? Function()? pendingCommitCritical,
    PublishStagger? stagger,
    DateTime Function()? now,
    bool throwOnShutdown = false,
  }) {
    final log = <String>[];
    final engine = _RecordingEngine(log);
    final publisher = _RecordingPublisher(log);
    final maintenance = _RecordingMaintenance(log);
    final shutdowns = <int>[0];
    final openOutcomes = <int>[];
    final coordinator = BackgroundBurstCoordinator(
      engine: engine,
      publisher: publisher,
      maintenance: maintenance,
      stagger: stagger ?? PublishStagger.none(),
      shutdownPublishPool: () async {
        shutdowns[0]++;
        log.add('shutdown');
        if (throwOnShutdown) throw StateError('shutdown boom');
      },
      burstEnabled: burstEnabled ?? () => true,
      // Mirrors the coordinator's own defaults; the test that OMITS both
      // proves they really are these.
      foregrounded: foregrounded ?? () => false,
      pendingCommitCritical: pendingCommitCritical ?? () => null,
      onOpenOutcome: openOutcomes.add,
      now: now ?? () => DateTime(2026, 9, 7, 12),
    );
    return _Env(
      log: log,
      engine: engine,
      publisher: publisher,
      maintenance: maintenance,
      coordinator: coordinator,
      shutdowns: shutdowns,
      openOutcomes: openOutcomes,
    );
  }

  /// Ticks [circle], keyed by its display name (the scheduler's key stands in
  /// for the hex `nostrGroupId` here — what matters is that the sink and the
  /// roster agree on it), first registering it in the publisher's roster the
  /// way a real tick can only come from a circle the scheduler tracks.
  Future<void> tick(_Env env, Circle circle) {
    env.publisher.roster[circle.displayName] = circle;
    return env.coordinator.onTick(
      circleKey: circle.displayName,
      circle: circle,
    );
  }

  group('the burst sequence', () {
    test('a tick opens, drains, publishes, folds maintenance, settles, '
        'pauses and closes the pool — in that order', () async {
      final env = build();

      await tick(env, _circle('a', 1));

      expect(env.log, [
        'open',
        'backlog',
        'window',
        'publish:a',
        'kp',
        'relayList',
        'settle',
        'pause',
        'shutdown',
      ]);
    });

    test('the burst opens with openBackgroundBurst, never the foreground '
        're-anchor', () async {
      // `resumeAfterBackground()` re-anchors and ALWAYS carries the inbox REQ,
      // so routing bursts through it would leave the k-th-burst inbox fold
      // permanently un-applied and re-request 49 h of `#p` gift wraps every
      // 72-168 s. Nothing about that is visible at runtime: no error, no
      // failing publish. The engine fake throws if the wrong entry point is
      // ever used, which is the only place this can be caught in Dart.
      final env = build();

      await tick(env, _circle('a', 1));

      expect(env.engine.opens, 1);
      expect(env.log, contains('open'));
    });

    test('one GPS window serves every circle in a burst', () async {
      final env = build();
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      env.publisher.duringPublish = () async {
        unawaited(tick(env, b));
      };
      await tick(env, a);

      expect(env.publisher.published, ['a', 'b']);
      expect(
        env.publisher.windows,
        hasLength(1),
        reason: 'a burst pays for one fix, however many circles are due',
      );
    });

    test('a refused publish window still settles, pauses and closes the pool',
        () async {
      final env = build()..publisher.refuseWindow = true;

      await tick(env, _circle('a', 1));

      expect(env.publisher.published, isEmpty);
      expect(env.log.sublist(env.log.length - 3), [
        'settle',
        'pause',
        'shutdown',
      ]);
    });
  });

  group('serialization and joining', () {
    test('a second tick during a burst joins it instead of opening a second '
        'socket', () async {
      final env = build();
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      // B's tick lands while A is being encrypted.
      final joined = Completer<void>();
      env.publisher.duringPublish = () async {
        unawaited(tick(env, b).whenComplete(joined.complete));
      };
      await tick(env, a);
      await joined.future;

      expect(env.publisher.published, ['a', 'b']);
      expect(
        env.engine.opens,
        1,
        reason: 'joining is the whole point: a second open would be a second '
            'radio wake seconds after the first',
      );
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a tick for a circle this burst ALREADY published runs in a second '
        'burst, never twice in one', () async {
      final env = build();
      final a = _circle('a', 1);

      Future<void>? second;
      env.publisher.duringPublish = () async {
        // A is mid-encrypt; its own next tick cannot join this burst.
        second = tick(env, a);
      };
      await tick(env, a);
      await second;

      expect(env.publisher.published, ['a', 'a']);
      expect(env.engine.opens, 2);
      expect(env.engine.pauses, 2);
      expect(
        env.log.where((e) => e == 'open').length,
        env.log.where((e) => e == 'pause').length,
        reason: 'every open is matched by a pause',
      );
    });

    test('a tick that lands after the publish pass closed gets its own burst',
        () async {
      // The failure this rules out is silent and expensive: a tick arriving
      // during the fold or the settle cannot be published by a pass that is
      // already over, so treating it as "joined" would drop it until the
      // circle's OWN next cadence — up to two publish intervals, which is
      // wider than the kind-445 retention window, so peers would watch the
      // marker go stale.
      final env = build();
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      Future<void>? late;
      env.maintenance.duringFold = () async {
        late = tick(env, b);
      };
      await tick(env, a);
      await late;

      expect(env.publisher.published, ['a', 'b']);
      expect(env.engine.opens, 2);
      expect(env.engine.pauses, 2);
    });

    test('two ticks that arrive while idle share one burst', () async {
      final env = build();
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      final first = tick(env, a);
      final second = tick(env, b);
      await Future.wait([first, second]);

      expect(env.publisher.published, unorderedEquals(['a', 'b']));
      expect(env.engine.opens, 1, reason: 'the second burst finds nothing due');
      expect(env.engine.pauses, 1);
    });

    test('a tick during the OPEN joins that burst', () async {
      // The burst's first ≤ 10 s are the open and the backlog wait, and a
      // circle's cadence can put a tick inside them. Joinable only after the
      // open, that tick queues a SECOND burst — a whole connect / REQ / CLOSE
      // / disconnect cycle seconds after the first, which is both the presence
      // pattern and the battery cost this phase exists to remove.
      final env = build();
      final gate = Completer<void>();
      env.engine.openGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final joined = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, joined]);

      expect(env.engine.opens, 1);
      expect(env.publisher.published, unorderedEquals(['a', 'b']));
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a tick during the WINDOW joins that burst and shares its fix',
        () async {
      // The window is the burst's longest link before it publishes anything —
      // an identity read, a disclosure read and a one-shot GPS fix — so a
      // circle's tick lands inside it routinely. It must be carried by the
      // burst that is already holding a fix, not dropped and not charged a
      // second one: a second window would take a second GPS fix for a burst
      // that already has one, and dropping it costs that circle a whole
      // cadence for a window that SUCCEEDED.
      final env = build();
      final gate = Completer<void>();
      env.publisher.windowGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(
        env.publisher.windows,
        [
          ['a'],
        ],
        reason: 'anti-vacuity: the window is open, and B is not in it',
      );

      final inside = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, inside]);

      expect(env.publisher.published, unorderedEquals(['a', 'b']));
      expect(
        env.publisher.windows,
        hasLength(1),
        reason: 'the joiner shares the fix this burst already paid for',
      );
      expect(env.engine.opens, 1);
      expect(env.engine.pauses, 1);
    });

    test('a tick during the BACKLOG wait joins that burst', () async {
      final env = build();
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final joined = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, joined]);

      expect(env.engine.opens, 1);
      expect(env.publisher.published, unorderedEquals(['a', 'b']));
      expect(
        env.publisher.windows,
        hasLength(1),
        reason: 'a joiner that arrived before the window shares its fix',
      );
    });

    test('a tick during the OPEN queues no burst behind one that published '
        'nothing', () async {
      // The sharp case for joining early. When the burst DOES publish, a tick
      // that failed to join is harmless — the running pass drains the due set
      // and the burst queued behind it finds nothing and returns. When the
      // window refuses (a dead GPS, a revoked permission), the due set is
      // still full when the burst ends, so that queued burst finds work and
      // opens a whole second connect / REQ / CLOSE / disconnect cycle seconds
      // after the first: the wake, and the presence pattern, this phase
      // exists to remove.
      final env = build()..publisher.refuseWindow = true;
      final gate = Completer<void>();
      env.engine.openGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final joined = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, joined]);

      expect(env.publisher.published, isEmpty, reason: 'the window refused');
      expect(env.engine.opens, 1);
      expect(env.publisher.windows, hasLength(1));
      expect(env.engine.pauses, 1);
    });

    test('a tick during the BACKLOG wait queues no burst behind one that '
        'published nothing', () async {
      final env = build()..publisher.refuseWindow = true;
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final joined = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, joined]);

      expect(env.engine.opens, 1);
      expect(env.publisher.windows, hasLength(1));
      expect(env.engine.pauses, 1);
    });

    test('a joining tick completes only when the burst carrying it does',
        () async {
      // The scheduler chains its links, so the future handed back is what
      // makes the chain measure real work. Completing it early lets the next
      // tick run while this burst still holds both sockets — and the whole
      // point of a chain is that it does not.
      final env = build();
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      var joinedDone = false;
      Future<void>? joined;
      env.publisher.duringPublish = () async {
        final b = tick(env, _circle('b', 2));
        unawaited(b.whenComplete(() => joinedDone = true));
        joined = b;
      };
      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();

      expect(env.log, contains('settle'), reason: 'the burst is tearing down');
      expect(
        joinedDone,
        isFalse,
        reason: 'the carrying burst has not settled, paused or closed its '
            'pool yet',
      );

      gate.complete();
      await Future.wait([first, joined!]);
      expect(joinedDone, isTrue);
      expect(env.publisher.published, ['a', 'b']);
    });

    test('a tick during the TEARDOWN queues behind the burst, never beside it',
        () async {
      // The scheduler's watchdog can let its own chain move on while a burst
      // is still tearing down. Two bursts running at once would hold two sets
      // of sockets and race two engine re-anchors, so the serialization that
      // prevents it has to be the coordinator's, not the chain's.
      final env = build();
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final second = tick(env, _circle('b', 2));
      await pumpEventQueue();

      expect(
        env.engine.opens,
        1,
        reason: 'the second burst may not open while the first is settling',
      );

      gate.complete();
      await Future.wait([first, second]);
      expect(env.engine.opens, 2);
      expect(env.engine.pauses, 2);
    });

    test('runningBurst is the burst in flight and null when idle', () async {
      final env = build();
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      expect(env.coordinator.runningBurst, isNull);
      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(env.coordinator.runningBurst, isNotNull);

      gate.complete();
      await burst;
      expect(env.coordinator.runningBurst, isNull);
    });

    test('runningBurst stays non-null through the teardown', () async {
      // The opt-out edge reads this to decide whether to pause the engine
      // itself. Null while the burst is inside its own settle, it pauses and
      // shuts the pool underneath the burst — a disconnect with a commit
      // between SEND and OK (Security Rule 13), which forks the group rather
      // than costing a sample.
      final env = build();
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();

      expect(env.log, contains('settle'), reason: 'anti-vacuity: it is there');
      expect(env.coordinator.runningBurst, isNotNull);

      gate.complete();
      await burst;
      expect(env.coordinator.runningBurst, isNull);
    });
  });

  group('the burst always closes', () {
    test('a burst that throws mid-chain still settles, pauses and closes the '
        'pool', () async {
      final env = build()..publisher.throwOnPublish = true;

      await tick(env, _circle('a', 1));

      expect(env.engine.settles, 1);
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
      expect(env.log.last, 'shutdown');
    });

    test('a throw from the backlog wait still pauses', () async {
      final env = build()..engine.throwOnBacklog = true;

      await tick(env, _circle('a', 1));

      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a throw from the settle link does not skip the pause', () async {
      // The settle and the pause are two links of one teardown. Guarding them
      // together would let a settle failure leave the sockets open for the
      // whole gap to the next burst.
      final env = build()..engine.throwOnSettle = true;

      await tick(env, _circle('a', 1));

      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a throw from the pause link does not skip the pool shutdown',
        () async {
      // The third link of the same teardown, and the one a merged guard would
      // swallow silently: the pause and the shutdown close DIFFERENT sockets.
      // A pause that throws (a logout racing the burst) with the shutdown
      // skipped leaves the PUBLISH pool's socket up for the whole gap to the
      // next tick — the presence signal this phase exists to remove, on the
      // pool nothing else closes.
      final env = build()..engine.throwOnPause = true;

      await tick(env, _circle('a', 1));

      expect(env.engine.settles, 1);
      expect(
        env.shutdownCount,
        1,
        reason: 'a failed pause must not cost the publish pool its shutdown',
      );
    });

    test('a burst that threw before its publish pass leaves the NEXT tick '
        'able to open one', () async {
      // The burst is joinable from its start until its publish pass ends, and
      // a throw anywhere in between must still close that window. Latched
      // open, every later tick joins this already-finished chain, queues
      // nothing and returns immediately: no error, no log, and background
      // sharing stops for the rest of the window.
      final env = build()..engine.throwOnBacklog = true;

      await tick(env, _circle('a', 1));
      expect(
        env.publisher.published,
        isEmpty,
        reason: 'anti-vacuity: the throw landed before the publish pass',
      );

      env.engine.throwOnBacklog = false;
      await tick(env, _circle('b', 2));

      expect(env.engine.opens, 2);
      expect(env.publisher.published, unorderedEquals(['a', 'b']));
      expect(env.engine.pauses, 2);
    });

    test('a throw from the pool shutdown does not poison the chain', () async {
      final env = build(throwOnShutdown: true);

      await tick(env, _circle('a', 1));
      await tick(env, _circle('b', 2));

      expect(env.engine.pauses, 2);
    });

    test('a teardown that throws does not latch the burst flag', () async {
      // `_bursting` is cleared in a `finally` NESTED inside the teardown's, so
      // a throw out of `_closeBurst` cannot skip it. Latched true,
      // `runningBurst` answers non-null for the life of the coordinator, and
      // every resume from then on takes the burst-in-flight bypass past the
      // 60 s re-anchor throttle: a pool reconnect and a 49 h `#p` gift-wrap
      // replay for every glance, forever.
      var handbackReads = 0;
      final env = build(
        // The burst's own gate reads it once before the pass; the teardown
        // re-reads it before each of its links.
        foregrounded: () {
          if (++handbackReads > 1) throw StateError('handback read boom');
          return false;
        },
      );

      await tick(env, _circle('a', 1));

      expect(
        env.log,
        ['open', 'backlog', 'window', 'publish:a', 'kp', 'relayList'],
        reason: 'anti-vacuity: the throw landed in the teardown, before the '
            'settle',
      );
      expect(env.coordinator.runningBurst, isNull);
    });

    test('a maintenance fold that throws still lets the burst close',
        () async {
      final env = build()..maintenance.throwOnKeyPackage = true;

      await tick(env, _circle('a', 1));

      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a KeyPackage fold that throws does not cost the relay list its fold',
        () async {
      // Two independent publishes of the user's own reachability. Guarded
      // together, one bad KeyPackage relay silently skips the relay-list fold
      // — and the next chance at it is 30 minutes away, so a device whose
      // relay list is stale stays unreachable that much longer for no reason
      // anyone can see.
      final env = build()..maintenance.throwOnKeyPackage = true;

      await tick(env, _circle('a', 1));

      expect(env.maintenance.relayListAt, hasLength(1));
      expect(env.engine.pauses, 1);
    });

    test('a failed open skips the backlog wait, still publishes, and still '
        'pauses', () async {
      // The engine puts `paused` back on every failure exit, but only the
      // dominant one also cuts the radio — and the caller cannot tell which
      // exit it got. So the burst pauses regardless (idempotent, and the one
      // thing that closes a socket the early exit left up), and the publish
      // pool is shut either way. Waiting for a backlog nobody requested would
      // spend the whole budget learning nothing; the publish rides the
      // separate publish pool and still gets through.
      final env = build()..engine.throwOnOpen = true;

      await tick(env, _circle('a', 1));

      expect(env.log, isNot(contains('backlog')));
      expect(env.publisher.published, ['a']);
      expect(env.engine.settles, 1);
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
      expect(env.engine.isPaused, isTrue);
    });

    test('the publish socket is shut down after every burst', () async {
      final env = build();

      await tick(env, _circle('a', 1));
      await tick(env, _circle('b', 2));
      await tick(env, _circle('c', 3));

      expect(env.shutdownCount, 3);
      expect(env.engine.pauses, 3);
    });

    test('the engine is paused after every burst', () async {
      final env = build();

      for (var i = 1; i <= 3; i++) {
        await tick(env, _circle('c$i', i));
      }

      expect(env.engine.pauses, env.engine.opens);
      expect(env.engine.isPaused, isTrue);
    });
  });

  group('cooperative cancellation (background sharing toggled off)', () {
    test('a burst cancelled between links still settles, pauses and closes',
        () async {
      var enabled = true;
      final env = build(burstEnabled: () => enabled);
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      // Consent withdrawn while the burst waits on its backlog.
      enabled = false;
      gate.complete();
      await burst;

      expect(env.publisher.published, isEmpty, reason: 'consent is withdrawn');
      expect(
        env.publisher.windows,
        isEmpty,
        reason: 'no GPS fix may be taken after the user withdrew consent — '
            'the publish that would have justified it is not going to happen',
      );
      expect(env.engine.settles, 1);
      expect(env.engine.pauses, 1);
      expect(
        env.shutdownCount,
        1,
        reason: 'opting out must leave NO socket, on either pool',
      );
    });

    test('cancellation during one publish stops the next one in the same '
        'pass', () async {
      var enabled = true;
      final env = build(burstEnabled: () => enabled);
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      final first = tick(env, a);
      final second = tick(env, b);
      env.publisher.duringPublish = () async {
        enabled = false;
      };
      await Future.wait([first, second]);

      expect(
        env.publisher.published,
        hasLength(1),
        reason: 'consent is re-read before each encrypt, not once per pass',
      );
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('cancellation stops a circle that joined mid-burst', () async {
      var enabled = true;
      final env = build(burstEnabled: () => enabled);
      final a = _circle('a', 1);
      final b = _circle('b', 2);

      env.publisher.duringPublish = () async {
        unawaited(tick(env, b));
        enabled = false;
      };
      await tick(env, a);

      expect(env.publisher.published, ['a']);
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('cancellation inside a stagger GAP stops the publish the gap was '
        'holding', () {
      // The consent read sits after the wait, not before it, for the half no
      // zero-gap test can see: a gap is seconds long, and a withdrawal inside
      // one must stop the publish it was holding rather than the one after
      // that. Checked before the wait, the burst encrypts and sends a location
      // the user withdrew consent for several seconds earlier.
      fakeAsync((async) {
        var enabled = true;
        final env = build(
          burstEnabled: () => enabled,
          // A fixed gap: the subject is WHERE the read sits, not the sampling.
          stagger: PublishStagger(
            minGap: const Duration(seconds: 4),
            maxGap: const Duration(seconds: 4),
          ),
        );

        unawaited(tick(env, _circle('a', 1)));
        unawaited(tick(env, _circle('b', 2)));
        async.flushMicrotasks();
        expect(
          env.publisher.published,
          hasLength(1),
          reason: 'anti-vacuity: the first publish takes no gap, so the burst '
              'is now inside the gap before the second',
        );

        async.elapse(const Duration(seconds: 2));
        enabled = false;
        async.elapse(const Duration(seconds: 10));

        expect(
          env.publisher.published,
          hasLength(1),
          reason: 'the publish the gap was holding must not go out',
        );
        expect(env.engine.pauses, 1);
        expect(env.shutdownCount, 1);
      });
    });

    test('cancellation during the OPEN skips the backlog wait', () async {
      // The wait is up to 5 s of radio spent ingesting a backlog this burst
      // will publish nothing from. Opting out has to stop it.
      var enabled = true;
      final env = build(burstEnabled: () => enabled);
      final gate = Completer<void>();
      env.engine.openGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      enabled = false;
      gate.complete();
      await burst;

      expect(env.log, isNot(contains('backlog')));
      expect(env.publisher.published, isEmpty);
      expect(env.publisher.windows, isEmpty);
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('a tick that arrives after consent was withdrawn opens nothing',
        () async {
      final env = build(burstEnabled: () => false);

      await tick(env, _circle('a', 1));

      expect(env.engine.opens, 0);
      expect(
        env.engine.pauses,
        0,
        reason: 'nothing was opened, so there is nothing to pause — the '
            'lifecycle edge pauses directly in that case',
      );
    });

    test('maintenance is not folded once consent is withdrawn', () async {
      var enabled = true;
      final env = build(burstEnabled: () => enabled);
      env.publisher.duringPublish = () async {
        enabled = false;
      };

      await tick(env, _circle('a', 1));

      expect(env.maintenance.keyPackageAt, isEmpty);
      expect(env.maintenance.relayListAt, isEmpty);
      expect(env.engine.pauses, 1);
    });
  });

  group('maintenance fold', () {
    test('runs by direct call, after the publish, at the burst clock',
        () async {
      final at = DateTime(2026, 9, 7, 12, 34, 56);
      final env = build(now: () => at);

      await tick(env, _circle('a', 1));

      expect(env.maintenance.keyPackageAt, [at]);
      expect(env.maintenance.relayListAt, [at]);
      expect(
        env.log.indexOf('kp'),
        greaterThan(env.log.indexOf('publish:a')),
        reason: 'the fold rides the pool the publish just warmed',
      );
      expect(env.log.indexOf('relayList'), greaterThan(env.log.indexOf('kp')));
      expect(env.log.indexOf('kp'), lessThan(env.log.indexOf('settle')));
    });

    test('a burst calls the fold exactly once per task', () async {
      // Twice would double the reachability publishes a burst pays for, and
      // the direct-call shape makes that a one-character mistake.
      final env = build();

      await tick(env, _circle('a', 1));

      expect(env.log.where((e) => e == 'kp'), hasLength(1));
      expect(env.log.where((e) => e == 'relayList'), hasLength(1));
    });
  });

  group('decorrelation inside a burst', () {
    test('consecutive publishes in one burst are separated by more than a '
        'second', () {
      // The engine binds the outer kind-445 `created_at` to the inner event's
      // WHOLE-SECOND timestamp, so two circles published in the same second
      // carry a byte-identical field inside a signed event — transferable
      // evidence linking two otherwise-unlinkable pseudonymous circles to one
      // device. Folding several circles into one burst is exactly the shape
      // that produces it, so the burst must stagger too.
      fakeAsync((async) {
        final env = build(stagger: PublishStagger());
        final a = _circle('a', 1);
        final b = _circle('b', 2);

        unawaited(tick(env, a));
        unawaited(tick(env, b));
        async
          ..flushMicrotasks()
          ..elapse(const Duration(milliseconds: 999));
        expect(
          env.publisher.published,
          hasLength(1),
          reason: 'the second publish must not land in the same second',
        );
        async.elapse(kPublishStaggerMaxGap);
        expect(env.publisher.published, hasLength(2));
      });
    });

    test('the order circles publish in is re-shuffled every burst', () async {
      // The due set is insertion-ordered, so without the CSPRNG permutation a
      // burst's order is just the scheduler's tick order — stable across every
      // burst. That makes one circle permanently the un-delayed one and fixes
      // the whole sequence relative to it: a second-order fingerprint of the
      // same burst, readable from the archives the gaps exist to protect.
      final env = build(
        stagger: PublishStagger(
          rng: Random(7),
          minGap: Duration.zero,
          maxGap: Duration.zero,
          maxSpread: Duration.zero,
        ),
      );
      final circles = [_circle('a', 1), _circle('b', 2), _circle('c', 3)];

      final orders = <String>{};
      for (var burst = 0; burst < 8; burst++) {
        env.publisher.published.clear();
        await Future.wait([for (final c in circles) tick(env, c)]);
        expect(
          env.publisher.published,
          unorderedEquals(['a', 'b', 'c']),
          reason: 'a permutation may not drop or duplicate a circle',
        );
        orders.add(env.publisher.published.join());
      }

      expect(
        orders,
        hasLength(greaterThan(1)),
        reason: 'eight bursts of the same three circles must not all publish '
            'in one order',
      );
    });
  });

  group('a circle that stops being publishable', () {
    test('is never published to, however long it has been due', () async {
      // A circle enters the due set at tick time and the burst publishes up to
      // a minute later. In between the engine can flag it Unrecoverable, or
      // the user can leave it — and a blocked circle must never be sent to
      // ("the UI MUST block send/mutate for a blocked circle"). Re-reading the
      // roster at fire time is the same check the foreground tick makes.
      final env = build();
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      final first = tick(env, _circle('a', 1));
      final second = tick(env, _circle('b', 2));
      await pumpEventQueue();
      env.publisher.roster.remove('b');
      gate.complete();
      await Future.wait([first, second]);

      expect(env.publisher.published, ['a']);
      expect(
        env.publisher.windows,
        [
          ['a'],
        ],
        reason: 'nor may a blocked circle be counted as a reason to take a fix',
      );
    });

    test('leaves the due set instead of waiting in it for every later burst',
        () async {
      // The due set only ever lost a circle to a successful encrypt or a
      // withdrawal, so an ineligible one stayed queued for the life of the
      // process, and every later burst would carry it the moment it became
      // publishable again — off its own cadence, on someone else's tick.
      //
      // Proved through the ELIGIBILITY drop, never through a refused window:
      // a refusal drains the whole due set on its own, so a test that went
      // that way passes with this drop deleted (it did, and so did the same
      // test before the refusal drain existed).
      final env = build();
      final gate = Completer<void>();
      env.engine.backlogGate = gate;
      final a = _circle('a', 1);

      final first = tick(env, a);
      await pumpEventQueue();
      // Left, blocked or flagged Unrecoverable while the burst was waiting.
      env.publisher.roster.remove('a');
      gate.complete();
      await first;

      expect(env.engine.opens, 1, reason: 'anti-vacuity: the burst DID run');
      expect(
        env.publisher.published,
        isEmpty,
        reason: 'A was due and stopped being eligible before the pass',
      );
      expect(
        env.publisher.windows,
        isEmpty,
        reason: 'nor may a circle that cannot be sent to buy a GPS fix',
      );

      // Publishable again — but nothing has ticked for it since, so no burst
      // may carry it.
      env.publisher.roster['a'] = a;
      await tick(env, _circle('b', 2));

      expect(env.publisher.published, ['b']);
      expect(env.publisher.windows.last, ['b']);
    });

    test('a circle flagged Unrecoverable MID-pass is not published by that '
        'pass', () async {
      // The pass reads its pending set ONCE per round, and a round is as long
      // as its publishes plus its stagger gaps. Only consent was re-read
      // inside the loop, so a circle the engine flagged after the round began
      // was still sent to — for the rest of the round — which is the one
      // thing `CircleService` says must never happen (Rule 8). The two
      // existing eligibility tests both drop the circle BEFORE the pass, so
      // neither can see it.
      final env = build();
      final a = _circle('a', 1);
      final b = _circle('b', 2);
      env.publisher.roster
        ..['a'] = a
        ..['b'] = b;
      // Whichever circle the CSPRNG puts first, the OTHER is flagged while
      // that publish is in flight.
      env.publisher.duringPublish = () async {
        final firstOut = env.publisher.published.single;
        env.publisher.roster.remove(firstOut == 'a' ? 'b' : 'a');
      };

      final burst = env.coordinator.onTick(circleKey: 'a', circle: a);
      unawaited(env.coordinator.onTick(circleKey: 'b', circle: b));
      await burst;

      expect(
        env.publisher.published,
        hasLength(1),
        reason: 'the circle flagged mid-pass must not be encrypted; only the '
            'one already in flight goes out',
      );
      expect(
        env.publisher.windows,
        hasLength(1),
        reason: 'anti-vacuity: one burst, one shared window — the pass did '
            'reach both circles',
      );
    });
  });

  group('a refused window costs ONE burst, not one per circle', () {
    // A pause queues every eligible circle at once. When the shared publish
    // window refuses — no identity yet, disclosure not accepted, permission
    // revoked, or a one-shot fix that timed out — every circle stayed due, so
    // the burst queued behind opened again, refused again, and so on: one cold
    // connect, one REQ set replaying 49 h of `#p` gift wraps and one pool
    // cycle PER DUE CIRCLE, publishing nothing, on the branch this phase
    // exists to keep quiet.

    test('four circles queued at once open one burst, refused or not',
        () async {
      final env = build()..publisher.refuseWindow = true;
      final circles = [
        _circle('a', 1),
        _circle('b', 2),
        _circle('c', 3),
        _circle('d', 4),
      ];

      await Future.wait([for (final circle in circles) tick(env, circle)]);

      expect(env.engine.opens, 1);
      expect(env.publisher.windows, hasLength(1));
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
      expect(env.publisher.published, isEmpty, reason: 'the window refused');

      // The same four ticks with the window OPEN: one burst, exactly as
      // before. That equality is the property — the cost of a burst may not
      // depend on whether the device could take a fix.
      env.publisher.refuseWindow = false;
      await Future.wait([for (final circle in circles) tick(env, circle)]);

      expect(env.engine.opens, 2);
      expect(env.publisher.windows, hasLength(2));
      expect(env.engine.pauses, 2);
      expect(env.shutdownCount, 2);
      expect(
        env.publisher.published,
        unorderedEquals(['a', 'b', 'c', 'd']),
      );
    });

    test('ticks that land during the TEARDOWN of a refusing burst share one '
        'burst too', () async {
      // The half no caller can fix from outside: these ticks arrive past
      // `_joinable` with the chain still pending, so each queues its own
      // burst. Only draining the due set at the refusal keeps the burst they
      // queue from multiplying the same way.
      final env = build()..publisher.refuseWindow = true;
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(env.log, contains('settle'), reason: 'anti-vacuity: mid-teardown');

      final queued = [_circle('b', 2), _circle('c', 3), _circle('d', 4)];
      final late = [for (final circle in queued) tick(env, circle)];
      gate.complete();
      await Future.wait([first, ...late]);

      expect(
        env.engine.opens,
        2,
        reason: 'the burst that was tearing down, and ONE for the three ticks '
            'that queued behind it',
      );
      expect(env.publisher.windows, hasLength(2));
      expect(env.engine.pauses, 2);
      expect(env.shutdownCount, 2);
      expect(env.publisher.published, isEmpty);
    });

    test('a tick that lands INSIDE the refused window is dropped with the '
        'rest', () async {
      // The window is seconds long — an identity read, a disclosure read and a
      // one-shot GPS fix — and a circle's tick can land inside it. It joins a
      // burst whose window is already being refused, and the refusal belongs
      // to the device, so it has nothing to publish either. Kept due, it would
      // ride the NEXT burst instead: a publish off its own jittered cadence,
      // on another circle's tick, which is the co-timing the per-circle
      // schedules exist to prevent.
      final env = build()..publisher.refuseWindow = true;
      final gate = Completer<void>();
      env.publisher.windowGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(
        env.publisher.windows,
        [
          ['a'],
        ],
        reason: 'anti-vacuity: the window is open and holds only A',
      );
      final inside = tick(env, _circle('b', 2));
      gate.complete();
      await Future.wait([first, inside]);

      env.publisher
        ..refuseWindow = false
        ..windowGate = null;
      await tick(env, _circle('c', 3));

      expect(
        env.publisher.windows.last,
        ['c'],
        reason: "B's tick was spent on the burst that refused; only its own "
            'next tick may bring it back',
      );
      expect(env.publisher.published, ['c']);
    });

    test('a circle dropped by a refusal is published on its next tick',
        () async {
      // Dropping is not forgetting: the refusal belongs to the device, and the
      // circle's own cadence re-queues it. A transient refusal (a one-shot fix
      // that timed out) therefore costs one cadence, not a publish.
      final env = build()..publisher.refuseWindow = true;

      await tick(env, _circle('a', 1));
      expect(env.publisher.published, isEmpty);

      env.publisher.refuseWindow = false;
      await tick(env, _circle('a', 1));

      expect(env.publisher.published, ['a']);
      expect(env.engine.opens, 2);
    });
  });

  group('a failed open is evidence, not just a log line', () {
    test('a run of failed opens is reported, and a success clears it',
        () async {
      // A failed open leaves the burst with no subscription: it publishes and
      // ingests nothing. Persist it and the device publishes every 72-168 s
      // while peers' commits pile up — past the engine's retained past epochs
      // its kind-445s stop being decryptable for everyone, with relay acks
      // still coming back here and a frozen marker over there. Nothing else in
      // the app can see that, so the run has to reach the health model the way
      // a refused GPS window does.
      final env = build()..engine.throwOnOpen = true;

      await tick(env, _circle('a', 1));
      await tick(env, _circle('a', 1));
      expect(env.openOutcomes, [1, 2]);

      env.engine.throwOnOpen = false;
      await tick(env, _circle('a', 1));
      expect(
        env.openOutcomes,
        [1, 2, 0],
        reason: 'an open that worked is the recovery the model clears on',
      );

      env.engine.throwOnOpen = true;
      await tick(env, _circle('a', 1));
      expect(
        env.openOutcomes,
        [1, 2, 0, 1],
        reason: 'the run counts CONSECUTIVE failures, so it restarts at one',
      );
    });

    test('a burst that never opened reports nothing', () async {
      // Consent withdrawn before the burst ran: no open was attempted, so
      // there is no verdict about the receive plane to report either way.
      final env = build(burstEnabled: () => false);

      await tick(env, _circle('a', 1));

      expect(env.engine.opens, 0);
      expect(env.openOutcomes, isEmpty);
    });
  });

  group('the burst budget', () {
    test('is the sum of the links the burst itself awaits', () {
      // Spelled out so a changed budget has to be changed here too, and so
      // neither the GPS window nor the stagger term — the two the phase plan's
      // headline formula omits, though its own step 3 mandates the stagger —
      // can quietly vanish again.
      // Six circles, not three: at three the naive `maxSpreadFor` term and the
      // join-aware one happen to be equal, so a bound that went back to the
      // naive one would slip through.
      final stagger = PublishStagger();
      expect(
        burstBound(6, stagger),
        kBurstConnectBudget +
            kBurstBacklogBudget +
            kBurstWindowBudget +
            kBurstPublishBudget * 6 +
            burstStaggerSpread(6, stagger),
      );
      expect(burstBound(6, stagger), greaterThan(burstBound(5, stagger)));
    });

    test('prices the gaps a JOINING burst actually samples', () {
      // A burst grows: a tick that lands mid-pass joins it, so the k-th gap
      // was sampled while only k circles were pending — at the wider ceiling
      // that goes with the smaller burst. Pricing every gap at the burst's
      // final size understates an 11-circle burst's spread by about 30 s, and
      // the report would then blame the burst for time the stagger is entitled
      // to take.
      final stagger = PublishStagger();

      expect(burstStaggerSpread(1, stagger), Duration.zero);
      expect(burstStaggerSpread(2, stagger), stagger.maxGapFor(2));
      expect(
        burstStaggerSpread(11, stagger),
        greaterThan(stagger.maxSpreadFor(11)),
      );
      expect(
        burstStaggerSpread(11, stagger),
        greaterThan(kPublishStaggerMaxSpread),
        reason: 'the spread CAP is what the sampling can exceed as a burst '
            'grows — that is the term the naive figure hides',
      );
    });

    test('a small burst fits inside the chain watchdog and a large one does '
        'not', () {
      // The only place these two numbers meet. A whole burst has no honest
      // bound — its maintenance fold rides the commit ladder and its pause
      // ends in an uncapped Rule-13 drain — so this claims only what it can:
      // the links the burst owns, at the sizes they fit.
      final stagger = PublishStagger();
      expect(burstBound(3, stagger), lessThan(kPublishLinkTimeout));
      expect(burstBound(12, stagger), greaterThan(kPublishLinkTimeout));
    });

    test('an over-budget burst is reported', () async {
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      var clock = DateTime(2026, 9, 7, 12);
      final env = build(now: () => clock)
        ..publisher.duringPublish = () async {
          clock = clock.add(const Duration(minutes: 5));
        };

      await tick(env, _circle('a', 1));

      expect(logs.where((l) => l.contains('over budget')), hasLength(1));
    });

    test('a burst is NOT reported for time its maintenance fold spent',
        () async {
      // The fold publishes through the commit ladder (≈49 s per task) and a
      // generation's first KeyPackage tick waits up to a minute for the login
      // publish first, so a burst that folds a due task is legitimately much
      // longer than any bound on its own links. Measuring the report through
      // it — or through the teardown after it — makes the report fire on a
      // burst that did nothing wrong, and a report that cries wolf is one
      // nobody reads when the real thing happens.
      final logs = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = original);

      var clock = DateTime(2026, 9, 7, 12);
      final env = build(now: () => clock)
        ..maintenance.duringFold = () async {
          clock = clock.add(const Duration(minutes: 5));
        };

      await tick(env, _circle('a', 1));

      expect(env.maintenance.keyPackageAt, hasLength(1), reason: 'it folded');
      expect(logs.where((l) => l.contains('over budget')), isEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // The burst HEAD against the kind-445 retention.
  //
  // `burstBound` above pins the COMPOSITION of these budgets. What nothing
  // pinned until now is the SECONDS they add up to — and the record
  // (`INV-W-445-EXPIRATION-WINDOW`'s residual, `constants/location.dart`,
  // `SECURITY.md`) discloses that the sum CROSSES the 228 s NIP-40 retention
  // at four circles, so a peer's marker can expire before its replacement
  // lands at an ordinary roster. Moving a budget moved that figure silently.
  //
  // WHAT THIS IS NOT: a measurement. Every number below is arithmetic over
  // the shipped constants. Nothing in this tree observes an iOS background
  // burst on hardware — there is none (`docs/POWER_EFFICIENCY_PLAN.md` §2.5)
  // — and the simulator cannot suspend a process, so the physical checklist
  // in `docs/M7_BACKGROUND_SHARING.md` §6 stays the only real proof and is
  // DEFERRED. Read this as "the budgets we ship add up past the retention",
  // never as "a marker was watched expiring".
  // -------------------------------------------------------------------------
  group('the burst head against the kind-445 retention', () {
    /// `LOCATION_MESSAGE_RETENTION_SECS` (`haven-core/src/location/ttl.rs`),
    /// the lifetime the engine stamps into every kind-445's NIP-40 tag.
    ///
    /// A LITERAL, for the reason `publish_stagger_test.dart` spells out and
    /// one this sum makes sharper: written as `kLocationPublishMaxInterval +
    /// 2 * kTtlNetworkBufferSeconds` it cancels against the identical term in
    /// [headGap], and the crossing collapses to `head + spread > 60 s` — a
    /// statement that no longer tracks the cadence ceiling at all.
    const retention = Duration(seconds: 228);

    /// Worst REALIZED gap between two of ONE circle's kind-445s when the
    /// publisher is an iOS background burst: the cadence ceiling, plus the
    /// head that sits between the tick and the burst's first publish, plus
    /// the burst spread the circle can move across (lead one burst, trail
    /// the next).
    ///
    /// Read off the constants rather than restated, so a moved budget or a
    /// moved cadence ceiling changes what this computes.
    Duration headGap(int circles, PublishStagger stagger) =>
        kLocationPublishMaxInterval +
        kBurstConnectBudget +
        kBurstBacklogBudget +
        kBurstWindowBudget +
        stagger.maxSpreadFor(circles);

    /// The disclosed figures, in milliseconds, for every roster the account
    /// bound admits.
    ///
    /// LITERALS: these numbers ARE the disclosure, so a budget change must be
    /// a visible edit here rather than a silent re-derivation that carries the
    /// prose along with the proof. Not whole seconds throughout — the per-gap
    /// ceiling is an integer-millisecond division, so eight and ten circles
    /// land 5 ms and 3 ms under the saturated 238 s.
    const expectedMs = <int, int>{
      1: 208000,
      2: 217000,
      3: 226000,
      4: 235000,
      5: 238000,
      6: 238000,
      7: 238000,
      8: 237995,
      9: 238000,
      10: 237997,
    };

    test(
      'the iOS burst head crosses the 228 s retention from FOUR circles up — '
      'the disclosed 226/235/238 s, in seconds and not in composition',
      () {
        final stagger = PublishStagger();

        // The head the record quotes as "up to 40 s", derived from the three
        // budgets rather than restated: connect + backlog + the one GPS
        // window a burst pays however many circles are due.
        expect(
          kBurstConnectBudget + kBurstBacklogBudget + kBurstWindowBudget,
          const Duration(seconds: 40),
          reason: 'the head is the term the SCHEDULED no-gap bound omits; if '
              'it moves, every figure below moves with it',
        );

        // Anti-vacuity on the table itself: it must cover exactly the rosters
        // kMaxCirclesPerAccount admits, so raising the bound forces an edit
        // here instead of leaving the new rosters unpinned.
        expect(
          expectedMs.keys.toSet(),
          {for (var n = 1; n <= kMaxCirclesPerAccount; n++) n},
          reason: 'the disclosure is about every admissible roster',
        );

        for (final n in expectedMs.keys) {
          expect(
            headGap(n, stagger).inMilliseconds,
            expectedMs[n],
            reason: 'the realized gap at $n circles is a disclosed figure',
          );
        }

        // THE CROSSING, by equality on the boundary rather than as a trend.
        expect(headGap(3, stagger), const Duration(seconds: 226));
        expect(headGap(4, stagger), const Duration(seconds: 235));
        expect(headGap(5, stagger), const Duration(seconds: 238));

        for (var n = 1; n <= 3; n++) {
          expect(
            headGap(n, stagger),
            lessThanOrEqualTo(retention),
            reason: 'iOS background sharing is disclosed as inside the '
                'retention up to three circles; at $n it must be',
          );
        }
        for (var n = 4; n <= kMaxCirclesPerAccount; n++) {
          expect(
            headGap(n, stagger),
            greaterThan(retention),
            reason: 'the disclosure says a peer marker CAN expire before its '
                'replacement lands from four circles up; if $n no longer '
                'crosses, the record overstates the exposure and the entry '
                'must be corrected rather than left standing',
          );
        }

        // And the saturation the prose calls "238 s from five up": the spread
        // stops growing once the per-gap ceiling starts shrinking, so nothing
        // past four is worse than 238 s.
        for (var n = 5; n <= kMaxCirclesPerAccount; n++) {
          expect(
            headGap(n, stagger),
            lessThanOrEqualTo(const Duration(seconds: 238)),
            reason: 'a roster of $n must not exceed the disclosed ceiling',
          );
          expect(
            headGap(n, stagger),
            greaterThan(const Duration(seconds: 237)),
            reason: 'nor fall below it by more than the millisecond '
                'quantization of the per-gap ceiling',
          );
        }
      },
    );
  });

  group('the publish pool is never shut under a commit (Security Rule 13)', () {
    // The burst awaits its OWN publishes, so its own work is drained by
    // structure. The pool is not its own: while backgrounded on iOS the motion
    // trigger keeps running and publishes over the same pool, unawaited by and
    // invisible to the coordinator, and that path reaches the deferred-send
    // ladder — `publishEvent`, then `confirmPublished` on an ack or
    // `publishFailed` without one. `shutdownPublishPool` reaches
    // `RelayManager::shutdown`, i.e. `client.disconnect()` with no drain at
    // all (the engine's settle and pause drain a DIFFERENT pool), so a burst
    // that ends mid-ladder makes `wait_for_ok` fail on a commit a relay may
    // already have stored and served. The sender then rolls back a commit its
    // peers have applied: a roster fork, not a lost location sample.

    test('the shutdown waits, unbounded, for a ladder in flight', () async {
      final pool = _PublishPoolWork();
      final ladder = pool.start();
      final env = build(pendingCommitCritical: pool.read);

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();

      expect(
        env.engine.pauses,
        1,
        reason: 'the drain sits AFTER the engine pause — the engine has its '
            'own drain and this one is about the publish pool',
      );
      expect(
        env.shutdownCount,
        0,
        reason: 'the ladder is between SEND and OK; cutting the socket now '
            'makes it roll back a commit a relay may already hold',
      );

      ladder.complete();
      await burst;

      expect(env.shutdownCount, 1);
      expect(env.log.last, 'shutdown');
    });

    test('a ladder that STARTS during the drain is drained too', () async {
      // The motion trigger is not gated by the burst, so a publish can begin
      // inside the wait for the previous one. Draining once and shutting would
      // cut that one instead — the same fork, one publish later.
      final pool = _PublishPoolWork();
      final first = pool.start();
      final env = build(pendingCommitCritical: pool.read);

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(env.shutdownCount, 0, reason: 'anti-vacuity: the drain is open');

      final second = pool.start();
      first.complete();
      await pumpEventQueue();

      expect(
        env.shutdownCount,
        0,
        reason: 'a second ladder is now between SEND and OK',
      );

      second.complete();
      await burst;
      expect(env.shutdownCount, 1);
    });

    test('a ladder that starts during the SETTLE is still drained', () async {
      // The read is taken after the settle and the pause, which is what makes
      // it observe whatever survived them — and the settle is the long link,
      // ending in the engine's own uncapped publish drain.
      final pool = _PublishPoolWork();
      final env = build(pendingCommitCritical: pool.read);
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      expect(env.log, contains('settle'), reason: 'anti-vacuity: it is there');

      final ladder = pool.start();
      gate.complete();
      await pumpEventQueue();

      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 0, reason: 'read after the settle, not before');

      ladder.complete();
      await burst;
      expect(env.shutdownCount, 1);
    });

    test('a ladder that FAILS still lets the pool shut down', () async {
      // Reaching its own conclusion is the point: the ladder itself decides
      // confirm-or-roll-back and logs its cause. What must not happen is the
      // burst ending with the publish pool still open for the whole gap to the
      // next tick because a resolution threw.
      final pool = _PublishPoolWork();
      final ladder = pool.start();
      final env = build(pendingCommitCritical: pool.read);

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      ladder.completeError(StateError('ladder boom'));
      await burst;

      expect(env.shutdownCount, 1);
      expect(env.engine.pauses, 1);
    });

    test('a registry that answers with anything at all still ends the '
        'teardown', () {
      // The re-read is what adopts a ladder that started during the drain, and
      // it is also the loop a broken registry never leaves: an `() async =>`
      // closure where the contract asks for a field hands back a fresh,
      // already-resolved future on every read, and awaiting one is free. Left
      // unbounded that teardown never reaches the pool shutdown — no burst
      // completes again, both pools stay open, and background sharing ends for
      // the process with nothing in the log but one line repeating. The fake
      // gives up after twenty reads only so that a regression FAILS here
      // instead of hanging the suite in a microtask loop.
      fakeAsync((async) {
        var reads = 0;
        final env = build(
          pendingCommitCritical: () {
            reads++;
            return reads > 20 ? null : Future<void>.value();
          },
        );

        unawaited(tick(env, _circle('a', 1)));
        async.flushMicrotasks();

        expect(
          env.shutdownCount,
          1,
          reason: 'the teardown reached its end and closed the publish pool',
        );
        expect(
          reads,
          lessThanOrEqualTo(4),
          reason: 'the ladder found in flight, plus at most three adopted '
              'after it',
        );
      });
    });

    test('an unwired coordinator tears down exactly as it did before',
        () async {
      // Both new reads default to "nothing to drain, still backgrounded", so
      // a caller that has not wired them gets the behaviour it had. A default
      // that failed the other way would turn a missing line in `MapShell` into
      // a burst that never closes its sockets.
      final printed = <String>[];
      final original = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) printed.add(message);
      };
      addTearDown(() => debugPrint = original);

      final log = <String>[];
      final engine = _RecordingEngine(log);
      final publisher = _RecordingPublisher(log);
      final coordinator = BackgroundBurstCoordinator(
        engine: engine,
        publisher: publisher,
        maintenance: _RecordingMaintenance(log),
        stagger: PublishStagger.none(),
        shutdownPublishPool: () async => log.add('shutdown'),
        burstEnabled: () => true,
        onOpenOutcome: (_) {},
      );
      final circle = _circle('a', 1);
      publisher.roster['a'] = circle;

      await coordinator.onTick(circleKey: 'a', circle: circle);

      expect(log, [
        'open',
        'backlog',
        'window',
        'publish:a',
        'kp',
        'relayList',
        'settle',
        'pause',
        'shutdown',
      ]);
      expect(
        printed.where((l) => l.contains('draining commit-critical')),
        isEmpty,
        reason: 'with nothing wired there is nothing in flight to wait for, '
            'and a default that waited anyway would put every unwired burst '
            'through a drain nobody can end',
      );
    });
  });

  group('a resume hands the engine back to the foreground', () {
    // `burstEnabled` cannot see a resume: it reads the background-sharing
    // consent, which is still true with the app on screen. So a burst still in
    // flight when the user returns used to settle, pause and shut the pool
    // underneath a FOREGROUND session — and nothing recovers that inside the
    // window: `ensureRunning` reads `isRunning` (true across a pause), the
    // health tick short-circuits, and the health model's `refresh()`
    // early-returns while paused, so the banner holds at its last verdict
    // while the device receives nothing.

    test('a burst in flight at resume neither pauses nor shuts the pool',
        () async {
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);
      final gate = Completer<void>();
      env.engine.backlogGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      foregrounded = true; // the user returned; `MapShell` cleared the sink
      gate.complete();
      await burst;

      expect(
        env.publisher.published,
        ['a'],
        reason: 'the publish PASS is not cancelled — those locations are due, '
            'and dropping them would cost a circle its update for a whole '
            'cadence',
      );
      expect(env.engine.settles, 0);
      expect(env.engine.pauses, 0);
      expect(
        env.shutdownCount,
        0,
        reason: 'the foreground owns the publish pool now; shutting it would '
            'also cut whatever it has in flight',
      );
    });

    test('a resume inside the SETTLE stops before the pause', () async {
      // The settle ends in the engine's uncapped publish drain, so it is the
      // link a resume is likeliest to land inside. Read once at the top of the
      // teardown, the pause that follows it lands on the session the
      // foreground just re-anchored.
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      foregrounded = true;
      gate.complete();
      await burst;

      expect(env.engine.settles, 1, reason: 'anti-vacuity: it had started');
      expect(env.engine.pauses, 0);
      expect(env.shutdownCount, 0);

      // …and the burst still cleaned up after itself: the next pause's burst
      // publishes the same circle again rather than treating it as already
      // encrypted.
      foregrounded = false;
      await tick(env, _circle('a', 1));
      expect(env.publisher.published, ['a', 'a']);
      expect(env.engine.pauses, 1);
    });

    test('a resume inside the PAUSE stops before the pool shutdown', () async {
      // The engine pause has already gone out here — closing that residue is
      // the resume side's job (re-anchor after `runningBurst`, exactly as the
      // opt-out edge waits on it). What this coordinator can still protect is
      // the pool the foreground is publishing over.
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);
      final gate = Completer<void>();
      env.engine.pauseGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      foregrounded = true;
      gate.complete();
      await burst;

      expect(env.engine.pauses, 1, reason: 'anti-vacuity: it had started');
      expect(env.shutdownCount, 0);
    });

    test('a burst queued behind one opens nothing after the handback',
        () async {
      // A tick that arrived while paused can still be sitting on the chain at
      // resume. Opening then would replace the foreground anchor with a burst
      // one, which carries no inbox REQ — gift-wrapped invitations would stop
      // arriving until the next re-anchor, with nothing to show for it.
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final first = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final second = tick(env, _circle('b', 2));
      await pumpEventQueue();
      foregrounded = true;
      gate.complete();
      await Future.wait([first, second]);

      expect(env.engine.opens, 1);
      expect(env.publisher.published, ['a']);
      expect(env.engine.pauses, 0);
      expect(env.shutdownCount, 0);
    });

    test('the read is a pull, so the next pause tears down again', () async {
      // The same coordinator instance is re-installed on every pause
      // (`_burstCoordinator ??=`). A one-way latch would leave every burst
      // after the first resume holding its sockets open for the whole
      // background window — worse than the defect it fixes.
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);

      await tick(env, _circle('a', 1));
      expect(env.engine.pauses, 1);

      foregrounded = true;
      await tick(env, _circle('a', 1));
      expect(env.engine.opens, 1, reason: 'nothing runs while foregrounded');

      foregrounded = false;
      await tick(env, _circle('a', 1));

      expect(env.engine.opens, 2);
      expect(env.engine.pauses, 2);
      expect(env.publisher.published, ['a', 'a']);
      expect(env.shutdownCount, 2);
    });
  });

  group('an idle close is the teardown a pause with no burst still owes', () {
    // The iOS pause branch drives a burst only when a circle is eligible to
    // publish AND the last publish is outside `kLocationPublishOverlapGuard`.
    // Both exits left the FOREGROUND's standing REQ, its socket and the
    // crate's 55 s pinger up: to the first per-circle tick after a recent
    // publish — the dominant interaction, open/glance/background — and for the
    // WHOLE background window with nothing eligible, where no tick is ever
    // coming. `closeIdle` is what makes every pause on that branch end in the
    // same three links, whether or not it had anything to send.

    test('it settles, pauses and shuts the pool without opening or publishing',
        () async {
      final env = build();

      await env.coordinator.closeIdle();

      expect(env.log, ['settle', 'pause', 'shutdown']);
      expect(
        env.engine.opens,
        0,
        reason: 'a close must not REVEAL presence to close a socket: an open '
            'unsubscribes, reconnects and re-issues every REQ, and at the '
            'shipped INBOX_BURSTS_PER_REQ the 49 h `#p` gift-wrap query with '
            'it — presence at an instant that is not a publish, on exactly '
            'the plane this phase keeps quiet',
      );
      expect(
        env.publisher.published,
        isEmpty,
        reason: 'nothing was due; publishing anyway would re-send inside the '
            'overlap guard the pause branch just declined to spend',
      );
      expect(env.engine.settles, 1);
      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });

    test('it stops where the foreground takes the engine back', () async {
      // What distinguishes it from `MapShell.releaseBurstPlaneOnOptOut`, which
      // has no handback gate — correct there, because withdrawn consent must
      // leave no socket whatever the app is doing, and wrong here, where a
      // resume 300 ms after the pause must cancel the close rather than have
      // it pause an engine the foreground now owns. Routing this through the
      // opt-out static would also skip the Rule-13 drain below.
      final env = build(foregrounded: () => true);

      await env.coordinator.closeIdle();

      expect(env.log, isEmpty);
      expect(env.engine.pauses, 0);
      expect(env.shutdownCount, 0);
    });

    test('the pool shutdown waits, unbounded, for a ladder in flight',
        () async {
      // Security Rule 13, on the path a pause now takes MOST often: the motion
      // trigger keeps running while backgrounded and publishes over the SAME
      // pool, unawaited by and invisible to this coordinator. Cutting the
      // socket under a ladder between SEND and OK makes the sender roll back a
      // commit a relay may already have stored and served.
      final pool = _PublishPoolWork();
      final ladder = pool.start();
      final env = build(pendingCommitCritical: pool.read);

      final idle = env.coordinator.closeIdle();
      await pumpEventQueue();

      expect(
        env.engine.pauses,
        1,
        reason: 'the drain sits AFTER the engine pause — the engine has its '
            'own drain and this one is about the publish pool',
      );
      expect(env.shutdownCount, 0, reason: 'the ladder is between SEND and OK');

      ladder.complete();
      await idle;

      expect(env.log, ['settle', 'pause', 'shutdown']);
    });

    test('it never runs beside a burst', () async {
      // Two teardowns interleaved would pause the engine underneath a burst
      // that is still publishing, and shut the pool it is publishing over. The
      // chain is what stops it: an idle close queued while a burst runs is the
      // burst's successor, not its neighbour.
      final env = build();
      final gate = Completer<void>();
      env.publisher.windowGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      final idle = env.coordinator.closeIdle();
      await pumpEventQueue();
      expect(
        env.log,
        ['open', 'backlog', 'window'],
        reason: 'anti-vacuity: the burst is held inside its publish window, so '
            'an idle close that ran now would run beside it',
      );

      gate.complete();
      await Future.wait([burst, idle]);

      expect(env.log, [
        'open',
        'backlog',
        'window',
        'publish:a',
        'kp',
        'relayList',
        'settle',
        'pause',
        'shutdown',
        'settle',
        'pause',
        'shutdown',
      ]);
    });

    test('runningBurst is non-null while it runs', () async {
      // What makes a mid-pause opt-out WAIT for this close rather than pause
      // underneath it, and what lets `reanchorOnResume` order behind it. Both
      // read `runningBurst`, and both would act immediately on a null.
      final env = build();
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final idle = env.coordinator.closeIdle();
      await pumpEventQueue();

      expect(env.coordinator.runningBurst, isNotNull);

      gate.complete();
      await idle;

      expect(env.coordinator.runningBurst, isNull);
    });

    test('a tick that lands during an idle close queues behind it instead of '
        'opening beside it', () async {
      // The mirror of the row above, and the ordering only the ASSIGNMENT back
      // to the chain provides: `return _chain.then(…)` without it leaves the
      // chain pointing at the future the close started FROM, so a tick landing
      // a moment later finds an idle chain and opens a socket while the close
      // is still settling and pausing — the two teardowns beside each other
      // this class exists to rule out.
      final env = build();
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final idle = env.coordinator.closeIdle();
      await pumpEventQueue();
      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();

      expect(
        env.log,
        ['settle'],
        reason: 'anti-vacuity: the close is held inside its settle, so a burst '
            'opening now would run beside it',
      );

      gate.complete();
      await Future.wait([idle, burst]);

      expect(env.log, [
        'settle',
        'pause',
        'shutdown',
        'open',
        'backlog',
        'window',
        'publish:a',
        'kp',
        'relayList',
        'settle',
        'pause',
        'shutdown',
      ]);
    });

    test('a throw from the teardown neither escapes nor latches the flag',
        () async {
      // The teardown's handback read is caller-supplied and deliberately
      // unguarded (there is no safe answer to an unreadable one), so it is the
      // one thing that can still throw out of `_closeBurst`. Two consequences
      // if this close does not absorb it: an unhandled async error on a
      // lifecycle path (`unawaited(coordinator.closeIdle())`), and a
      // `_bursting` left latched — after which `runningBurst` answers non-null
      // forever and every resume takes the burst-in-flight bypass, spending a
      // pool reconnect and a 49 h `#p` gift-wrap replay per glance.
      final env = build(
        foregrounded: () => throw StateError('handback read boom'),
      );

      await expectLater(env.coordinator.closeIdle(), completes);

      expect(env.coordinator.runningBurst, isNull);
    });

    test('an idle close that threw still lets the next tick burst', () async {
      // The chain is shared. A rejected one is inherited by every later tick
      // AND every later close, none of which would run its body again for the
      // rest of the mount: background sharing stops with nothing in the log.
      var throwOnHandback = true;
      final env = build(
        foregrounded: () {
          if (throwOnHandback) throw StateError('handback read boom');
          return false;
        },
      );

      await env.coordinator.closeIdle();
      throwOnHandback = false;
      await tick(env, _circle('a', 1));

      expect(env.log, [
        'open',
        'backlog',
        'window',
        'publish:a',
        'kp',
        'relayList',
        'settle',
        'pause',
        'shutdown',
      ]);
    });

    test('a commit-critical read that throws still shuts the pool', () async {
      // In production that read is `mounted ? ref.read(…) : null` — a Riverpod
      // read, which throws on a disposed container. It sat outside every
      // `try`, so the throw escaped past the pool shutdown and left the socket
      // this whole method exists to close OPEN, for the whole gap to the next
      // tick.
      final env = build(
        pendingCommitCritical: () => throw StateError('drain read boom'),
      );

      await env.coordinator.closeIdle();

      expect(env.log, ['settle', 'pause', 'shutdown']);
      expect(env.shutdownCount, 1);
    });

    test('a handback followed by another pause closes the pool', () async {
      // The teardown that stops at a handback leaves the publish pool open —
      // correct, the foreground is publishing over it. What used to make that
      // a residual is that nothing closed it when the app went away AGAIN with
      // nothing due: `_shutdownPublishPool` was skipped at the pause and no
      // tick followed. The next pause's idle close is what closes it.
      var foregrounded = false;
      final env = build(foregrounded: () => foregrounded);
      final gate = Completer<void>();
      env.engine.settleGate = gate;

      final burst = tick(env, _circle('a', 1));
      await pumpEventQueue();
      foregrounded = true;
      gate.complete();
      await burst;
      expect(env.engine.settles, 1, reason: 'anti-vacuity: the settle ran');
      expect(env.engine.pauses, 0, reason: 'and the handback stopped it there');
      expect(env.shutdownCount, 0);

      foregrounded = false;
      await env.coordinator.closeIdle();

      expect(env.engine.pauses, 1);
      expect(env.shutdownCount, 1);
    });
  });
}
