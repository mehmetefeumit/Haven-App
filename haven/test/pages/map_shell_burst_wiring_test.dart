/// The parts of the P4 lifecycle wiring that are BEHAVIOUR, not shape: what a
/// mid-pause opt-out does to the sockets, what a resume does to a burst that
/// is still in flight, what an immediate pause-time burst costs for N circles,
/// and what a failed burst open tells the user.
///
/// Everything else about the wiring — which branch installs the coordinator,
/// which one clears it, the order of the resume — is structural and pinned in
/// `map_shell_location_access_lifecycle_test.dart` and
/// `map_shell_burst_collaborators_test.dart`, because `MapShell` reaches the
/// Rust bridge in `initState` and cannot be pumped (CLAUDE.md). These can be
/// executed, so they are: each is a promise with a failure mode nobody would
/// see until it had already cost a user something (a socket held open after
/// consent was withdrawn; a foregrounded app receiving nothing behind a
/// "healthy" banner; N cold connects to publish nothing; a banner naming the
/// wrong plane).
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/providers/sharing_health_provider.dart';
import 'package:haven/src/rust/api.dart' show BacklogOutcomeFfi, FfiGroupSpec;
import 'package:haven/src/services/background_burst_coordinator.dart';
import 'package:haven/src/services/circle_health_service.dart';
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/publish_stagger.dart';
import 'package:haven/src/services/subscription_service.dart';

import '../mocks/mock_circle_service.dart';

const _selfPubkey =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _peerPubkey =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// Reads a `haven-core` source file, so the Dart mirrors below are pinned to
/// the Rust they claim to mirror rather than to a comment saying they are.
String _rustSource(String relative) {
  final file = File('../haven-core/$relative');
  expect(
    file.existsSync(),
    isTrue,
    reason: '$relative moved — re-derive kOptOutBurstWait against wherever '
        'these ceilings live now, do not delete this pin',
  );
  return file.readAsStringSync();
}

/// The integer literal of a `const NAME: <int type> = <n>;` in [source].
int _rustConst(String source, String name) {
  final match = RegExp(
    'const $name: [A-Za-z0-9]+ = ([0-9_]+);',
  ).firstMatch(source);
  expect(match, isNotNull, reason: '$name is gone from the Rust source');
  return int.parse(match!.group(1)!.replaceAll('_', ''));
}

/// The seconds of a `const NAME: Duration = Duration::from_secs(n);`.
int _rustSecs(String source, String name) {
  final match = RegExp(
    'const $name: Duration = Duration::from_secs\\(([0-9_]+)\\);',
  ).firstMatch(source);
  expect(match, isNotNull, reason: '$name is gone from the Rust source');
  return int.parse(match!.group(1)!.replaceAll('_', ''));
}

/// The brace-balanced body of the Rust fn whose signature starts with
/// [signature].
String _rustFnBody(String source, String signature) {
  final at = source.indexOf(signature);
  expect(at, isNonNegative, reason: '$signature is gone from the Rust source');
  final open = source.indexOf('{', at);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}') {
      depth--;
      if (depth == 0) return source.substring(open, i + 1);
    }
  }
  fail('unbalanced braces in $signature');
}

/// Records the two teardown links the opt-out must always reach.
class _RecordingEngine implements SubscriptionService {
  final List<String> log = [];
  int pauses = 0;
  bool throwOnPause = false;

  /// A pause that never returns — the engine's uncapped
  /// `wait_publishes_drained()`, which is where a real one wedges. Completed
  /// by nothing: the point is that the OTHER link must not wait on it.
  Completer<void>? wedgePause;

  @override
  Future<void> pauseSubscriptions() async {
    pauses++;
    log.add('pause');
    if (throwOnPause) throw const SubscriptionServiceException('no session');
    final wedge = wedgePause;
    if (wedge != null) await wedge.future;
  }

  @override
  bool get isPaused => pauses > 0;

  @override
  bool get isRunning => true;

  // Nothing else is reachable from the opt-out edge; a call would be the test
  // silently exercising a different path.
  @override
  Future<void> openBackgroundBurst() async => throw UnimplementedError();

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async =>
      throw UnimplementedError();

  @override
  Future<void> settleBeforePause() async => throw UnimplementedError();

  @override
  Future<void> resumeAfterBackground() async => throw UnimplementedError();

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async => throw UnimplementedError();

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async =>
      throw UnimplementedError();

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async =>
      throw UnimplementedError();

  @override
  Future<LiveSyncStopOutcome> stop() async => throw UnimplementedError();
}

/// The engine as the RESUME edge sees it: it can be paused by something other
/// than the caller (a burst's teardown), and it counts re-anchors.
class _ResumeEngine implements SubscriptionService {
  int reanchors = 0;
  bool paused = false;
  bool throwOnReanchor = false;

  @override
  Future<void> resumeAfterBackground() async {
    reanchors++;
    paused = false;
    if (throwOnReanchor) throw const SubscriptionServiceException('no session');
  }

  @override
  bool get isPaused => paused;

  @override
  bool get isRunning => true;

  // The resume edge touches nothing else; a call would be the test silently
  // exercising a different path.
  @override
  Future<void> pauseSubscriptions() async => throw UnimplementedError();

  @override
  Future<void> openBackgroundBurst() async => throw UnimplementedError();

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async =>
      throw UnimplementedError();

  @override
  Future<void> settleBeforePause() async => throw UnimplementedError();

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async => throw UnimplementedError();

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async =>
      throw UnimplementedError();

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async =>
      throw UnimplementedError();

  @override
  Future<LiveSyncStopOutcome> stop() async => throw UnimplementedError();
}

/// A full burst engine, for the ONE-burst-per-pause proof: it counts the links
/// a burst costs, so "N ticks cost one burst" is measured rather than asserted
/// about a loop's shape.
class _BurstEngine implements SubscriptionService {
  int opens = 0;
  int settles = 0;
  int pauses = 0;

  @override
  Future<void> openBackgroundBurst() async => opens++;

  @override
  Future<BacklogOutcomeFfi> waitBacklogSettled() async =>
      BacklogOutcomeFfi.settled;

  @override
  Future<void> settleBeforePause() async => settles++;

  @override
  Future<void> pauseSubscriptions() async => pauses++;

  @override
  bool get isPaused => pauses > opens;

  @override
  bool get isRunning => true;

  @override
  Future<void> resumeAfterBackground() async => throw UnimplementedError();

  @override
  Future<void> start({
    required List<FfiGroupSpec> groups,
    required List<String> inboxRelays,
  }) async => throw UnimplementedError();

  @override
  Future<void> subscribeCircle(FfiGroupSpec spec) async =>
      throw UnimplementedError();

  @override
  Future<void> unsubscribeCircle(Uint8List nostrGroupId) async =>
      throw UnimplementedError();

  @override
  Future<LiveSyncStopOutcome> stop() async => throw UnimplementedError();
}

/// The scheduler's half of a burst, with a publish window that can refuse —
/// the state the multiplication only ever showed up in.
class _BurstPublisher implements BurstPublisher {
  _BurstPublisher(this.circles, {required this.refuseWindow});

  final Map<String, Circle> circles;
  final bool refuseWindow;
  int windows = 0;
  final List<String> published = [];

  @override
  Circle? eligibleCircle(String circleKey) => circles[circleKey];

  @override
  Future<BurstFix?> openBurstPublishWindow(Iterable<Circle> circles) async {
    windows++;
    return refuseWindow
        ? null
        : const BurstFix(
            senderPubkeyHex: _selfPubkey,
            latitude: 51.5,
            longitude: -0.1,
          );
  }

  @override
  Future<void> publishInBurst(Circle circle, BurstFix fix) async {
    published.add(circle.displayName);
  }
}

class _NoMaintenance implements BurstMaintenance {
  @override
  Future<void> runKeyPackageIfDue(DateTime now) async {}

  @override
  Future<void> runRelayListIfDue(DateTime now) async {}
}

/// In-memory [CircleHealthService] — the persisted half of the health model.
class _FakeHealthService implements CircleHealthService {
  CircleHealthTimestamps stored = CircleHealthTimestamps.none;

  @override
  Future<void> notePublishAcked({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    stored = CircleHealthTimestamps(
      lastPublishAckedAt: at,
      lastPeerEventAt: stored.lastPeerEventAt,
    );
  }

  @override
  Future<void> notePeerEvent({
    required List<int> nostrGroupId,
    required DateTime at,
  }) async {
    stored = CircleHealthTimestamps(
      lastPublishAckedAt: stored.lastPublishAckedAt,
      lastPeerEventAt: at,
    );
  }

  @override
  Future<CircleHealthTimestamps> read({
    required List<int> nostrGroupId,
  }) async => stored;
}

/// The sharing-health model on an injected clock, exactly as its own tests
/// drive it — so the verdict here is the REAL derivation, not a re-statement
/// of the mapping under test.
class _HealthHarness {
  _HealthHarness() : health = _FakeHealthService() {
    container = ProviderContainer(
      overrides: [
        sharingHealthClockProvider.overrideWithValue(() => now),
        circleHealthServiceProvider.overrideWithValue(health),
        selectedCircleProvider.overrideWithValue(
          TestCircleFactory.createCircle(
            mlsGroupId: const [1, 2, 3],
            nostrGroupId: const [9, 9],
            members: [
              TestCircleFactory.createMember(pubkey: _selfPubkey),
              TestCircleFactory.createMember(pubkey: _peerPubkey),
            ],
          ),
        ),
        identityProvider.overrideWith(
          (ref) async => Identity(
            pubkeyHex: _selfPubkey,
            npub: 'npub1self',
            createdAt: DateTime(2025),
          ),
        ),
        memberLocationsProvider.overrideWith(
          (ref) async => const <MemberLocation>[],
        ),
        sharingHealthForegroundProvider.overrideWithValue(foreground),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(foreground.dispose);
  }

  final _FakeHealthService health;
  final ValueNotifier<bool> foreground = ValueNotifier<bool>(true);
  late final ProviderContainer container;
  DateTime now = DateTime.utc(2026, 9, 7, 12);

  SharingHealthNotifier get notifier =>
      container.read(sharingHealthProvider.notifier);

  Future<SharingHealth> settle() async {
    await container.read(identityProvider.future);
    await container.read(memberLocationsProvider.future);
    await notifier.refresh();
    return container.read(sharingHealthProvider);
  }

  void advance(Duration by) => now = now.add(by);
}

void main() {
  group('the mid-pause opt-out leaves no socket', () {
    test('with no burst in flight it pauses the engine and shuts the pool',
        () async {
      // The C4 branch as it runs on a quiet background window: the toggle goes
      // off between two publish ticks, so nothing is open but the engine is
      // still subscribed from the last burst.
      final engine = _RecordingEngine();
      var shutdowns = 0;

      await MapShell.releaseBurstPlaneOnOptOut(
        engine: engine,
        shutdownPublishPool: () async => shutdowns++,
      );

      expect(engine.pauses, 1);
      expect(
        shutdowns,
        1,
        reason: 'withdrawn consent must not leave the engine subscribed or a '
            'publish socket open for the rest of the background window',
      );
    });

    test('a burst in flight reaches its own settle before the engine pauses',
        () async {
      // Pausing underneath a running burst would cut its ingest mid-replay and
      // truncate the settle that exists to keep a commit between SEND and OK
      // from losing its ack (Security Rule 13). So the edge WAITS.
      final engine = _RecordingEngine();
      final burst = Completer<void>();
      var shutdowns = 0;
      var released = false;

      unawaited(
        MapShell.releaseBurstPlaneOnOptOut(
          engine: engine,
          shutdownPublishPool: () async => shutdowns++,
          runningBurst: burst.future,
        ).then((_) => released = true),
      );
      await pumpEventQueue();

      expect(engine.pauses, 0, reason: 'the burst had not finished yet');
      expect(shutdowns, 0);

      burst.complete();
      await pumpEventQueue();

      expect(released, isTrue);
      expect(engine.pauses, 1);
      expect(shutdowns, 1);
    });

    test('a wedged burst does not hold the opt-out open', () {
      // The failure this bound exists for: `settleBeforePause` ends in an
      // UNCAPPED publish-gauge wait (Rule 13, by design), so a burst that
      // wedges there never completes. An unbounded wait here would leave the
      // socket up for the rest of the process's life — with consent already
      // withdrawn.
      fakeAsync((async) {
        final engine = _RecordingEngine();
        final wedged = Completer<void>();
        var shutdowns = 0;
        var released = false;

        unawaited(
          MapShell.releaseBurstPlaneOnOptOut(
            engine: engine,
            shutdownPublishPool: () async => shutdowns++,
            runningBurst: wedged.future,
          ).then((_) => released = true),
        );

        async.elapse(kOptOutBurstWait - const Duration(seconds: 1));
        expect(
          engine.pauses,
          0,
          reason: 'a burst that is merely slow must be allowed to finish its '
              'own teardown — the wait is what keeps this edge from cutting a '
              'healthy settle short',
        );

        async
          ..elapse(const Duration(seconds: 2))
          ..flushMicrotasks();

        expect(released, isTrue, reason: 'the wait is bounded');
        expect(
          engine.pauses,
          1,
          reason: 'on expiry the pause is issued anyway; it cannot cut a '
              'commit between SEND and OK, because the engine drains its own '
              'in-flight publish gauge before it disconnects',
        );
        expect(shutdowns, 1);

        // Anti-vacuity: the burst really never completed, so the pause above
        // came from the bound and not from the burst finishing.
        expect(wedged.isCompleted, isFalse);
      });
    });

    test('a burst that fails still ends in a pause and a shut pool', () async {
      // The coordinator's chain absorbs its own errors, so this is defence in
      // depth — but "no socket" may not depend on the future we are waiting on
      // completing successfully.
      final engine = _RecordingEngine();
      var shutdowns = 0;

      await MapShell.releaseBurstPlaneOnOptOut(
        engine: engine,
        shutdownPublishPool: () async => shutdowns++,
        runningBurst: Future<void>.error(StateError('burst boom')),
      );

      expect(engine.pauses, 1);
      expect(shutdowns, 1);
    });

    test('a pause that throws does not skip the pool shutdown', () async {
      // The two links are independent sockets. `pauseSubscriptions` throws on
      // `NoSession` (a logout that raced the opt-out), and the publish pool is
      // still open at that point.
      final engine = _RecordingEngine()..throwOnPause = true;
      var shutdowns = 0;

      await MapShell.releaseBurstPlaneOnOptOut(
        engine: engine,
        shutdownPublishPool: () async => shutdowns++,
      );

      expect(shutdowns, 1);
    });

    test('a shutdown that throws never escapes the lifecycle callback',
        () async {
      // It is launched with `unawaited` from a `listenManual` callback: an
      // escaping error there is an unhandled async error, not a caught one.
      final engine = _RecordingEngine();

      await expectLater(
        MapShell.releaseBurstPlaneOnOptOut(
          engine: engine,
          shutdownPublishPool: () async => throw StateError('pool boom'),
        ),
        completes,
      );
    });

    test('a WEDGED pause does not starve the pool shutdown', () {
      // THE failure the sequential shape had. The two links used to be
      // sequential `await`s in independent try/catches — which contains a
      // THROW and nothing else. `pauseSubscriptions` ends in the engine's
      // uncapped `wait_publishes_drained()` (Rule 13, by design), the same
      // wedge `kOptOutBurstWait` exists for, and a wedged one meant the
      // shutdown behind it never ran at all: consent withdrawn, publish
      // sockets open for the life of the process.
      //
      // Neither link may be bounded with a `.timeout(` — it cancels no Rust
      // future and would only let this return with a commit between SEND and
      // OK. So independence is the bound, and this is what proves it.
      fakeAsync((async) {
        final engine = _RecordingEngine()..wedgePause = Completer<void>();
        var shutdowns = 0;

        unawaited(
          MapShell.releaseBurstPlaneOnOptOut(
            engine: engine,
            shutdownPublishPool: () async => shutdowns++,
          ),
        );
        async
          ..elapse(const Duration(hours: 6))
          ..flushMicrotasks();

        expect(
          engine.pauses,
          1,
          reason: 'the pause was ISSUED — the wedge is inside it, not before',
        );
        expect(
          shutdowns,
          1,
          reason: 'withdrawn consent must leave no publish socket open, and '
              'that promise may not be conditional on the ENGINE being '
              'healthy — a wedged drain is exactly when the sockets matter',
        );
        // Anti-vacuity: the pause really never returned, so the shutdown above
        // did not simply follow a completed link.
        expect(engine.wedgePause!.isCompleted, isFalse);
      });
    });

    test('a wedged BURST still reaches both links, not just the first', () {
      // The two bounds compose: the burst wait expires, and the pause it hands
      // over to wedges as well. Both were sequential, so this was two starved
      // links in a row.
      fakeAsync((async) {
        final engine = _RecordingEngine()..wedgePause = Completer<void>();
        final wedgedBurst = Completer<void>();
        var shutdowns = 0;

        unawaited(
          MapShell.releaseBurstPlaneOnOptOut(
            engine: engine,
            shutdownPublishPool: () async => shutdowns++,
            runningBurst: wedgedBurst.future,
          ),
        );
        async
          ..elapse(kOptOutBurstWait + const Duration(seconds: 1))
          ..flushMicrotasks();

        expect(engine.pauses, 1);
        expect(shutdowns, 1);
        expect(wedgedBurst.isCompleted, isFalse);
      });
    });
  });

  group("kOptOutBurstWait is derived from the engine's own ceilings", () {
    // The value used to be 38 s, priced as "one 10 s relay OK wait" for the
    // whole of `pause_subscriptions`. That is the CRATE's per-relay
    // `wait_for_ok`, not the engine's pause, which spends four separately
    // bounded lifecycle ops before it even reaches the drain. So the wait
    // expired on HEALTHY bursts and the direct pause ran underneath one —
    // exactly what waiting exists to avoid.
    //
    // Nothing failed when it was wrong, and nothing failed when it was raised
    // to six HOURS either, which is the real gap: a derived constant with no
    // test is a comment. These rows are the arithmetic, and the Rust rows
    // below are the terms.

    test('it is the sum of the three ceilings its doc names', () {
      expect(
        kOptOutBurstWait,
        kBurstPublishBudget + // the single-attempt publish it is inside
            const Duration(seconds: 18) + // BURST_SETTLE_CAP_SECS
            const Duration(seconds: 4 * 10), // 4 x RELAY_LIFECYCLE_OP_TIMEOUT
        reason: 'the wait must price what a cancelled burst still owes: its '
            'publish, its settle, and the BOUNDED prefix of its pause',
      );
      expect(kOptOutBurstWait, const Duration(seconds: 68));
    });

    test('the burst publish budget is the whole ladder, and it is one attempt',
        () {
      // If `LOCATION_PUBLISH_ATTEMPTS` ever stops being 1, the first term is
      // no longer one connect + one ack window and this derivation is wrong.
      final manager = _rustSource('src/relay/manager.rs');
      expect(
        _rustConst(manager, 'LOCATION_PUBLISH_ATTEMPTS'),
        1,
        reason: 'the location ladder is one attempt; the 3-attempt ladder is '
            'the COMMIT path, which no publish pass takes',
      );
      expect(
        kBurstPublishBudget,
        Duration(
          seconds:
              _rustSecs(manager, 'CONNECTION_TIMEOUT') +
              _rustSecs(manager, 'LOCATION_ACK_WINDOW'),
        ),
      );
    });

    test("the settle cap term is the engine's BURST_SETTLE_CAP_SECS", () {
      expect(
        _rustConst(
          _rustSource('src/relay/live_sync/config.rs'),
          'BURST_SETTLE_CAP_SECS',
        ),
        18,
      );
    });

    test('the pause term is every bounded step the pause takes', () {
      final config = _rustSource('src/relay/live_sync/config.rs');
      expect(_rustConst(config, 'RELAY_LIFECYCLE_OP_TIMEOUT_SECS'), 10);

      // Counted, not assumed. `pause_subscriptions` bounds `unsubscribe_all`,
      // the leftover-subscription probe, the `RawSignal::Pause` send and the
      // worker's ack of it — four steps it always takes — plus ONE MORE per
      // leftover REQ, inside the sweep loop. That fifth site is why the count
      // here is 5 and the multiplier in the constant is 4.
      final body = _rustFnBody(
        _rustSource('src/relay/live_sync/session.rs'),
        'pub async fn pause_subscriptions',
      );
      expect(
        'RELAY_LIFECYCLE_OP_TIMEOUT'.allMatches(body).length,
        5,
        reason: 'the pause gained or lost a bounded step — re-derive '
            'kOptOutBurstWait rather than leaving it priced for the old one',
      );
      expect(
        body.contains('self.processor.wait_publishes_drained().await'),
        isTrue,
        reason: 'the uncapped Rule-13 drain is what makes this a BOUND and '
            'not an await; if it went away, the wait could become one',
      );
    });
  });

  group('a resume never leaves the engine paused by a burst', () {
    // The burst that starts at the pause instant runs for 2-4 s, and the
    // glance-and-return pattern lands 1-3 s later — INSIDE it. Clearing the
    // tick sink cancels nothing, and the coordinator's consent read cannot
    // cancel it either: background sharing is still ON in the foreground.
    //
    // The coordinator stops its teardown as soon as the foreground owns the
    // engine, which covers everything except a `pauseSubscriptions` already
    // under way. That one completes — after the resume's own re-anchor — and
    // nothing recovers it: `ensureRunning` reads `isRunning` (true across a
    // pause), the periodic heal short-circuits on it, `_fullRestart` declines
    // while paused, and `SharingHealthNotifier.refresh()` early-returns while
    // paused, so the banner holds at "healthy" while the device receives
    // nothing until the next full background→foreground cycle.

    test('with no burst in flight it re-anchors exactly once', () async {
      final engine = _ResumeEngine()..paused = true;

      await MapShell.reanchorOnResume(engine: engine);

      expect(engine.reanchors, 1);
      expect(engine.isPaused, isFalse);
    });

    test('a burst that pauses BEHIND the re-anchor is repaired', () async {
      final engine = _ResumeEngine();
      final burst = Completer<void>();

      final resume = MapShell.reanchorOnResume(
        engine: engine,
        burstInFlight: burst.future,
      );
      await pumpEventQueue();
      expect(
        engine.reanchors,
        1,
        reason: 'the foreground re-anchors AT ONCE — it must not wait out a '
            'burst before the map has a subscription',
      );

      // The burst reaches the `pauseSubscriptions()` it had already entered.
      engine.paused = true;
      burst.complete();
      await resume;

      expect(
        engine.reanchors,
        2,
        reason: 'a foregrounded app left with a paused engine receives '
            'nothing, and nothing else in the app can see it: every periodic '
            'repair reads isRunning, which a pause leaves true',
      );
      expect(engine.isPaused, isFalse);
    });

    test('a burst that leaves the engine live costs no second re-anchor',
        () async {
      // The common case now that the coordinator stops its teardown on the
      // handback. A second re-anchor is not free: it reconnects the pool and
      // re-issues every REQ, the inbox one replaying 49 hours of gift wraps
      // keyed on this npub.
      final engine = _ResumeEngine();

      await MapShell.reanchorOnResume(
        engine: engine,
        burstInFlight: Future<void>.value(),
      );

      expect(engine.reanchors, 1);
    });

    test('a burst that FAILS still gets its engine checked', () async {
      // The coordinator's chain absorbs its own errors, so this is defence in
      // depth — but the repair may not depend on the future it waits on
      // completing successfully.
      final engine = _ResumeEngine();
      final burst = Completer<void>();

      final resume = MapShell.reanchorOnResume(
        engine: engine,
        burstInFlight: burst.future,
      );
      await pumpEventQueue();
      engine.paused = true;
      burst.completeError(StateError('burst boom'));
      await resume;

      expect(engine.reanchors, 2);
    });

    test('a re-anchor that throws never escapes the lifecycle callback',
        () async {
      // Launched with `unawaited` from `_onResumed`, where an escaping error
      // is an unhandled async error rather than a caught one.
      final engine = _ResumeEngine()..throwOnReanchor = true;

      await expectLater(
        MapShell.reanchorOnResume(engine: engine),
        completes,
      );
    });
  });

  group('a foregrounded app is never left with a paused engine', () {
    // `reanchorOnResume` gets exactly ONE attempt, and the layers under it are
    // built to give up quietly: `resume_after_background` exhausts the
    // engine's subscribe attempts, and a burst's `resume_burst` re-pauses and
    // stays silent — right for a burst, whose next tick retries in 72-168 s,
    // wrong for a foreground that has no next tick. A user returning while the
    // radio is cold (a captive portal, a dead zone, a lock-screen unlock)
    // therefore lands foregrounded with a paused engine.
    //
    // Nothing else in the app sees it: `ensureRunning` reads `isRunning`,
    // which a pause leaves TRUE; the subscription-health tick short-circuits
    // on the paused state; a circle-set delta only stages into the engine's
    // model; and `_fullRestart` declines outright. Publishing keeps acking on
    // the SEPARATE publish pool, so the sharing banner stays green while the
    // map receives nothing — until another full background→foreground cycle.

    final t0 = DateTime.utc(2026, 9, 7, 12);

    test('a paused engine is re-anchored with no further pause/resume cycle',
        () async {
      final engine = _ResumeEngine()..paused = true;

      final took = await MapShell.reanchorPausedEngine(
        engine: engine,
        foregrounded: true,
        now: t0,
      );

      expect(took, isTrue, reason: 'the caller records it as a re-anchor');
      expect(engine.reanchors, 1);
      expect(engine.isPaused, isFalse);
    });

    test('a running engine costs one isPaused read and nothing else', () async {
      final engine = _ResumeEngine();

      expect(
        await MapShell.reanchorPausedEngine(
          engine: engine,
          foregrounded: true,
          now: t0,
        ),
        isFalse,
      );
      expect(engine.reanchors, 0);
    });

    test('a paused engine is left alone while the app is AWAY', () async {
      // The heal timer is cancelled at every pause, but `_startLiveSync`
      // re-arms it from its own completion, which can land after one. A
      // re-anchor there is the pre-P4 shape: standing REQs and a socket put
      // back BETWEEN bursts, at an instant that is not a publish (R14).
      final engine = _ResumeEngine()..paused = true;

      expect(
        await MapShell.reanchorPausedEngine(
          engine: engine,
          foregrounded: false,
          now: t0,
        ),
        isFalse,
      );
      expect(engine.reanchors, 0);
      expect(engine.isPaused, isTrue);
    });

    test('it declines inside the throttle the resume just stamped', () async {
      // `_onResumed` records the instant BEFORE it launches its own re-anchor,
      // so a heal running behind it must not spend a second pool reconnect and
      // a second 49 h `#p` gift-wrap replay on the same repair.
      final engine = _ResumeEngine()..paused = true;

      expect(
        await MapShell.reanchorPausedEngine(
          engine: engine,
          foregrounded: true,
          now: t0,
          lastReanchorAt: t0.subtract(const Duration(seconds: 5)),
        ),
        isFalse,
      );
      expect(engine.reanchors, 0);
    });

    test('and takes it once the throttle has elapsed', () async {
      // The heal cadence is 90-150 s, so a repair that is genuinely owed is
      // always outside the 60 s window by the time the next tick lands.
      final engine = _ResumeEngine()..paused = true;

      expect(
        await MapShell.reanchorPausedEngine(
          engine: engine,
          foregrounded: true,
          now: t0,
          lastReanchorAt: t0.subtract(const Duration(seconds: 61)),
        ),
        isTrue,
      );
      expect(engine.reanchors, 1);
    });

    test('a re-anchor that FAILED still counts, so it cannot spin', () async {
      // The engine is still paused afterwards and the next tick will find it
      // that way. Reporting the attempt is what keeps the retry on the heal's
      // own 90-150 s cadence instead of on whatever cadence a caller invents.
      final engine = _ResumeEngine()
        ..paused = true
        ..throwOnReanchor = true;

      expect(
        await MapShell.reanchorPausedEngine(
          engine: engine,
          foregrounded: true,
          now: t0,
        ),
        isTrue,
      );
      expect(engine.reanchors, 1);
    });
  });

  group('an immediate pause-time burst costs ONE burst for N circles', () {
    // Driven against the REAL coordinator, because the claim is about how
    // `onTick` queues — a claim about the shape of a loop would be satisfied
    // by the defect.

    ({
      _BurstEngine engine,
      _BurstPublisher publisher,
      BackgroundBurstCoordinator coordinator,
      List<({String key, Circle circle})> ticks,
    }) harness({required int circles, required bool refuseWindow}) {
      final roster = <String, Circle>{};
      final ticks = <({String key, Circle circle})>[];
      for (var i = 0; i < circles; i++) {
        final circle = TestCircleFactory.createCircle(
          displayName: 'circle $i',
          mlsGroupId: [i],
          nostrGroupId: [i, i],
        );
        final key = sharingCircleKey(circle.nostrGroupId);
        roster[key] = circle;
        ticks.add((key: key, circle: circle));
      }
      final engine = _BurstEngine();
      final publisher = _BurstPublisher(roster, refuseWindow: refuseWindow);
      return (
        engine: engine,
        publisher: publisher,
        ticks: ticks,
        coordinator: BackgroundBurstCoordinator(
          engine: engine,
          publisher: publisher,
          maintenance: _NoMaintenance(),
          stagger: PublishStagger.none(),
          shutdownPublishPool: () async {},
          burstEnabled: () => true,
          onOpenOutcome: (_) {},
        ),
      );
    }

    test('a REFUSED publish window still costs exactly one', () async {
      // The measured defect: all N ticks were issued in one synchronous sweep,
      // so none of them found a burst running and each queued its own; and a
      // refused window returns without draining the due set, so bursts 2..N
      // did not find it empty either. Four circles cost four opens, four
      // pauses, four pool cycles and four REQ sets — each replaying 49 hours
      // of `#p` gift wraps — to publish nothing at all.
      final h = harness(circles: 4, refuseWindow: true);

      await MapShell.queueOneBurst(h.coordinator, h.ticks);
      await pumpEventQueue();

      expect(h.engine.opens, 1, reason: 'one burst, not one per circle');
      expect(h.engine.pauses, 1);
      expect(h.publisher.windows, 1);
      expect(
        h.publisher.published,
        isEmpty,
        reason: 'anti-vacuity: the window really did refuse, so the single '
            'open above is not a burst that simply succeeded',
      );
    });

    test('every circle still publishes when the window opens', () async {
      // The other half: batching must not cost a circle its publish.
      final h = harness(circles: 4, refuseWindow: false);

      await MapShell.queueOneBurst(h.coordinator, h.ticks);
      await pumpEventQueue();

      expect(h.engine.opens, 1);
      expect(
        h.publisher.published,
        // Unordered: the burst CSPRNG-shuffles its pass so a relay cannot
        // learn a circle ordering from two of them (publish decorrelation).
        unorderedEquals(['circle 0', 'circle 1', 'circle 2', 'circle 3']),
        reason: 'one burst covers the whole eligible set — the immediate '
            "pause burst is every circle's publish, which is why the pause "
            'stamps _lastPublishTime for all of them',
      );
    });

    test('no circle opens nothing at all', () async {
      // The empty set is the D4 cohort: with nothing eligible there is no
      // tick, so no burst — which is why the pause must close the socket
      // itself rather than leave it to a burst that never runs.
      final h = harness(circles: 0, refuseWindow: false);

      await MapShell.queueOneBurst(h.coordinator, h.ticks);
      await pumpEventQueue();

      expect(h.engine.opens, 0);
      expect(h.publisher.windows, 0);
    });

    test('one circle takes the single-tick path', () async {
      final h = harness(circles: 1, refuseWindow: false);

      await MapShell.queueOneBurst(h.coordinator, h.ticks);
      await pumpEventQueue();

      expect(h.engine.opens, 1);
      expect(h.publisher.published, ['circle 0']);
    });
  });

  group('a failed burst open is reported as a RECEIVE fault', () {
    test('a run of failed opens confirms receiveSubscriptionLost', () async {
      final h = _HealthHarness();
      expect(await h.settle(), SharingHealth.healthy);

      MapShell.recordBurstOpenOutcome(h.notifier, 1);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));

      final verdict = await h.settle();
      expect(verdict.state, SharingHealthState.paused);
      expect(
        verdict.pausedReason,
        SharingPausedReason.receiveSubscriptionLost,
        reason: 'a failed open leaves the burst with no subscription — it '
            'ingests nothing. Its publishes still ride the separate publish '
            'pool and still get their acks, so naming the send plane would '
            'point the user at a remedy for a fault they do not have',
      );
      expect(
        verdict.state,
        isNot(SharingHealthState.publishFailing),
        reason: 'the send plane is working; saying otherwise is a wrong cause, '
            'not a conservative one',
      );
    });

    test('one transient failed open never reaches the user', () async {
      // A burst open has no redundancy but plenty of retries: the next tick is
      // 72-168 s away. Reporting the first failure would make the banner fire
      // on ordinary relay flap.
      final h = _HealthHarness();

      MapShell.recordBurstOpenOutcome(h.notifier, 1);
      h.advance(kSharingFaultConfirmationWindow);

      expect(
        (await h.settle()).state,
        SharingHealthState.healthy,
        reason: 'exactly at the confirmation window is not yet past it',
      );
    });

    test('the first open that succeeds clears it', () async {
      final h = _HealthHarness();

      MapShell.recordBurstOpenOutcome(h.notifier, 3);
      h.advance(kSharingFaultConfirmationWindow + const Duration(seconds: 1));
      expect((await h.settle()).state, SharingHealthState.paused);

      // 0 = this open succeeded. Nothing else clears it — a peer location
      // arriving proves nothing about the subscription that was dropped.
      MapShell.recordBurstOpenOutcome(h.notifier, 0);
      h.advance(kSharingFaultConfirmationWindow * 10);

      expect(
        await h.settle(),
        SharingHealth.healthy,
        reason: 'the run ended, so the evidence for the fault is gone',
      );
    });
  });
}
