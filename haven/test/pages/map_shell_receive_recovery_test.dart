/// Pins `MapShell`'s receive-plane recovery contracts (Unit C).
///
/// Everything here exists because the receive plane could die while every
/// flag in the app still read healthy (`docs/BACKGROUND_SHARING_FAILURE_
/// ANALYSIS.md` §4 C3/C6): a failed first start left the app with no
/// re-subscriber and therefore no self-heal and no resume repair; and the only
/// thing that recovers a relay-dropped REQ sat behind a 30 s debounce that the
/// glance pattern reliably defeated — while being expensive enough that it
/// must not run on every glance either.
///
/// The decisions that CAN be pure are pure statics on [MapShell] and are tested
/// behaviourally. The rest is lifecycle wiring inside a `ConsumerState` that
/// per CLAUDE.md cannot be pumped without the Rust bridge (`MapPage` reaches
/// FFI in `initState`), so it is pinned over the source — the same fallback
/// `map_shell_detached_release_test.dart` uses. Those assertions are written to
/// fail if the wiring is removed, reordered, or widened.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart';

// The AST detectors for `map_shell.dart` live next door; a second copy here
// would be a second thing to keep correct about the same source.
import 'map_shell_burst_collaborators_test.dart'
    show assignmentsTo, conditionalArms, methodSource, namedArgumentsOf;

void main() {
  group('MapShell.shouldReanchorOnResume', () {
    final t0 = DateTime.utc(2026, 8, 28, 12);

    test('the first resume of a mount always re-anchors', () {
      // Anti-vacuity for the throttle below, and the case that matters: a user
      // reopening the app because peers vanished must get the repair.
      expect(
        MapShell.shouldReanchorOnResume(lastReanchorAt: null, now: t0),
        isTrue,
      );
    });

    test('a glance 5 s after the last one does NOT re-anchor', () {
      // Ten shade-pull glances must not become ten pool reconnects and ten
      // 96-hour gift-wrap replays, each wrap costing a secret materialisation
      // and an FFI NIP-59 unwrap.
      expect(
        MapShell.shouldReanchorOnResume(
          lastReanchorAt: t0,
          now: t0.add(const Duration(seconds: 5)),
        ),
        isFalse,
      );
    });

    test('a resume 61 s later re-anchors again', () {
      expect(
        MapShell.shouldReanchorOnResume(
          lastReanchorAt: t0,
          now: t0.add(const Duration(seconds: 61)),
        ),
        isTrue,
      );
    });

    test('the boundary is the overlap guard itself, exclusive', () {
      // Derived, not chosen: 60 s is the app's existing "do not repeat a relay
      // round-trip sooner than this" quantum AND numerically the resubscribe
      // clock-skew window, so a re-anchor inside it re-queries a window the
      // previous one already covered.
      expect(
        MapShell.shouldReanchorOnResume(
          lastReanchorAt: t0,
          now: t0.add(kLocationPublishOverlapGuard),
        ),
        isFalse,
        reason: 'exactly at the guard is not yet past it',
      );
      expect(
        MapShell.shouldReanchorOnResume(
          lastReanchorAt: t0,
          now: t0.add(
            kLocationPublishOverlapGuard + const Duration(seconds: 1),
          ),
        ),
        isTrue,
      );
    });
  });

  group('SingleFlight', () {
    test('concurrent callers share one run and one result', () async {
      // Startup and a resume-driven heal both park on the same
      // `circlesProvider` read. Two runs would build two re-subscribers over
      // one engine — two serialization chains interleaving stop/start against
      // a shared session (Security Rule 14) — and leak the loser's listener.
      final flight = SingleFlight<int>();
      final gate = Completer<void>();
      var runs = 0;

      Future<int> body() async {
        runs++;
        await gate.future;
        return runs;
      }

      final first = flight.run(body);
      final second = flight.run(body);
      expect(
        runs,
        1,
        reason: 'the latch must be set before the body can yield, or a caller '
            'arriving during the first await starts a second run',
      );

      gate.complete();
      expect(await Future.wait([first, second]), [1, 1]);
      expect(runs, 1);
    });

    test('a later caller runs it again once the first has settled', () {
      // It is a de-duplicator, not a once-only latch: the install is retried
      // on every heal tick.
      fakeAsync((async) {
        final flight = SingleFlight<int>();
        var runs = 0;
        Future<int> body() async => ++runs;

        unawaited(flight.run(body));
        async.flushMicrotasks();
        expect(flight.isBusy, isFalse);

        unawaited(flight.run(body));
        async.flushMicrotasks();
        expect(runs, 2);
      });
    });

    test('a throwing run releases the latch instead of wedging it', () {
      // A failed install must be retryable — latching here would reproduce the
      // exact defect this whole unit exists to fix.
      fakeAsync((async) {
        final flight = SingleFlight<int>();
        var runs = 0;
        Future<int> boom() async {
          runs++;
          throw Exception('install failed');
        }

        unawaited(flight.run(boom).catchError((Object _) => -1));
        async.flushMicrotasks();
        expect(flight.isBusy, isFalse);

        unawaited(flight.run(boom).catchError((Object _) => -1));
        async.flushMicrotasks();
        expect(runs, 2);
      });
    });
  });

  // The heal timer, on a fake clock. Every interval below is drawn from a
  // seeded generator the test replays, so "the base interval" is the exact
  // draw and not a range a doubled one could hide inside.
  group('LiveSyncHealBackstop', () {
    const seed = 20261011;
    const span = LiveSyncHealBackstop.maxSecs - LiveSyncHealBackstop.minSecs;

    /// The next base interval the backstop will draw, from a replay of its
    /// generator.
    Duration draw(math.Random replay) => Duration(
      seconds: LiveSyncHealBackstop.minSecs + replay.nextInt(span + 1),
    );

    /// Elapses to one second short of [interval], checks [heals] has not
    /// moved, then crosses it.
    void crossExpecting(
      FakeAsync async,
      Duration interval,
      int Function() heals, {
      required String reason,
    }) {
      final before = heals();
      async.elapse(interval - const Duration(seconds: 1));
      expect(heals(), before, reason: 'early: $reason');
      async.elapse(const Duration(seconds: 1));
      expect(heals(), before + 1, reason: reason);
    }

    test('a heal that stood down adds nothing to the back-off', () {
      // The user's own pause ended the start, or no session was wanted: that
      // says nothing about the relays. Counted, three quick visits put the
      // next tick up to twenty minutes out.
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return LiveSyncHealOutcome.stoodDown;
          },
        )..start();

        for (var tick = 0; tick < 6; tick++) {
          crossExpecting(
            async,
            draw(replay),
            () => heals,
            reason: 'tick $tick is one base interval after the last',
          );
        }
        expect(heals, 6, reason: 'six ticks, six base intervals');
        backstop.stop();
      });
    });

    test('after three quick visits the next tick is the base interval', () {
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return LiveSyncHealOutcome.stoodDown;
          },
        );

        for (var visit = 0; visit < 3; visit++) {
          // A resume: its own heal, then the timers. The pause that follows
          // ends that start before it comes up.
          unawaited(backstop.heal());
          backstop.start();
          async.flushMicrotasks();
          backstop.stop();
          // One draw by `start()`, one by the heal's own re-arm.
          draw(replay);
          draw(replay);
        }
        expect(heals, 3);

        unawaited(backstop.heal());
        backstop.start();
        async.flushMicrotasks();
        draw(replay);
        crossExpecting(
          async,
          draw(replay),
          () => heals,
          reason: 'a stood-down heal was counted as a failed restart',
        );
        backstop.stop();
      });
    });

    test('a restart that failed backs off, doubling to the cap', () {
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return LiveSyncHealOutcome.failed;
          },
        )..start();

        for (final multiplier in const [1, 2, 4, 8, 8, 8]) {
          crossExpecting(
            async,
            draw(replay) * multiplier,
            () => heals,
            reason: 'multiplier $multiplier',
          );
        }
        expect(heals, 6, reason: 'no tick came early, none was skipped');
        expect(LiveSyncHealBackstop.maxMultiplier, 8);
        backstop.stop();
      });
    });

    test('a heal that finds the engine running resets the back-off', () {
      fakeAsync((async) {
        final replay = math.Random(seed);
        final outcomes = [
          LiveSyncHealOutcome.failed,
          LiveSyncHealOutcome.failed,
          LiveSyncHealOutcome.running,
          LiveSyncHealOutcome.running,
        ];
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async => outcomes[heals++],
        )..start();

        for (final multiplier in const [1, 2, 4, 1]) {
          crossExpecting(
            async,
            draw(replay) * multiplier,
            () => heals,
            reason: 'multiplier $multiplier',
          );
        }
        backstop.stop();
      });
    });

    test('a stood-down heal neither adds to nor clears a real back-off', () {
      fakeAsync((async) {
        final replay = math.Random(seed);
        final outcomes = [
          LiveSyncHealOutcome.failed,
          LiveSyncHealOutcome.stoodDown,
          LiveSyncHealOutcome.stoodDown,
        ];
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async => outcomes[heals++],
        )..start();

        for (final multiplier in const [1, 2, 2]) {
          crossExpecting(
            async,
            draw(replay) * multiplier,
            () => heals,
            reason: 'multiplier $multiplier',
          );
        }
        backstop.stop();
      });
    });

    test("the resume's heal re-draws the tick from its own outcome", () {
      // `_onResumed` arms the timers before its heal has answered. Left at
      // that draw, a heal that brought the engine back would still wait out
      // the back-off of the failures before it.
      fakeAsync((async) {
        final replay = math.Random(seed);
        var outcome = LiveSyncHealOutcome.failed;
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return outcome;
          },
        )..start();
        for (final multiplier in const [1, 2, 4]) {
          async.elapse(draw(replay) * multiplier);
        }
        expect(heals, 3, reason: 'premise: three failed restarts');
        draw(replay);
        backstop.stop();

        // The resume.
        outcome = LiveSyncHealOutcome.running;
        unawaited(backstop.heal());
        backstop.start();
        async.flushMicrotasks();
        draw(replay);
        expect(heals, 4);

        crossExpecting(
          async,
          draw(replay),
          () => heals,
          reason: 'the next tick was left at eight times the base interval',
        );
        backstop.stop();
      });
    });

    test('a heal that never returns counts as a failed restart, and the '
        'backstop ticks on', () {
      // Its re-anchor waits on the engine's lifecycle lock, which a wedged
      // pause holds for the life of the process. Re-armed only from the
      // heal's completion, the backstop — the only periodic recovery the
      // live-sync build has — ended with that heal.
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () {
            heals++;
            return Completer<LiveSyncHealOutcome>().future;
          },
        )..start();
        async.elapse(draw(replay));
        expect(heals, 1, reason: 'premise: the first heal is out');

        for (final multiplier in const [2, 4]) {
          crossExpecting(
            async,
            LiveSyncHealBackstop.healDeadline + draw(replay) * multiplier,
            () => heals,
            reason: 'past its deadline a heal is a failed restart: the next '
                'tick is one back-off step further out (x$multiplier)',
          );
        }
        backstop.stop();
      });
    });

    test('a slow but healthy heal is not counted a failure', () {
      // A restart can take its whole budget and the re-anchor behind it more.
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            await Future<void>.delayed(
              kLiveSyncRestartBudget + const Duration(seconds: 30),
            );
            return LiveSyncHealOutcome.running;
          },
        )..start();
        async.elapse(draw(replay));
        expect(heals, 1);

        crossExpecting(
          async,
          kLiveSyncRestartBudget + const Duration(seconds: 30) + draw(replay),
          () => heals,
          reason: 'a heal that came back running re-arms at the base interval',
        );
        backstop.stop();
      });
    });

    test('a heal that completes after a stop does not re-arm', () {
      // The pause cancels the timer while a heal is in flight; that heal's
      // completion is the re-arm. Armed there, it ticks for the whole
      // background window.
      fakeAsync((async) {
        final replay = math.Random(seed);
        final inFlight = Completer<LiveSyncHealOutcome>();
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () {
            heals++;
            return inFlight.future;
          },
        )..start();
        async.elapse(draw(replay));
        expect(heals, 1, reason: 'premise: the tick is out');

        backstop.stop();
        inFlight.complete(LiveSyncHealOutcome.failed);
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(hours: 6));
        expect(heals, 1);
      });
    });

    test('a mount arms nothing unless the app reads resumed, and the first '
        'resumed arms', () {
      // A process the OS relaunched in the background mounts the shell under
      // the embedder's seed (`detached`), `inactive` or `paused`. Armed
      // there, every tick re-establishes a dead session with nobody looking.
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      addTearDown(
        () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
      );
      for (final away in const [
        AppLifecycleState.detached,
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        fakeAsync((async) {
          binding.handleAppLifecycleStateChanged(away);
          var heals = 0;
          final backstop = LiveSyncHealBackstop(
            random: math.Random(seed),
            heal: () async {
              heals++;
              return LiveSyncHealOutcome.failed;
            },
          )..startAtMount();
          expect(async.pendingTimers, isEmpty, reason: '$away');

          // The mount's own first start, failing: its completion arms
          // nothing either.
          unawaited(backstop.heal());
          async.flushMicrotasks();
          expect(async.pendingTimers, isEmpty, reason: '$away');
          async.elapse(const Duration(hours: 6));
          expect(heals, 1, reason: 'a tick ran in an app that is $away');

          // The resume handler's arming, at the first `resumed` dispatch.
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
          backstop.start();
          expect(async.pendingTimers, hasLength(1), reason: '$away');
          backstop.stop();
        });
      }
    });

    test('a mount in an app that reads resumed arms it', () {
      TestWidgetsFlutterBinding.ensureInitialized()
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return LiveSyncHealOutcome.running;
          },
        )..startAtMount();
        crossExpecting(
          async,
          draw(replay),
          () => heals,
          reason: 'a foreground launch has no heal timer',
        );
        backstop.stop();
      });
    });

    test('a stop cancels the tick that was armed, and a start arms one', () {
      fakeAsync((async) {
        final replay = math.Random(seed);
        var heals = 0;
        final backstop = LiveSyncHealBackstop(
          random: math.Random(seed),
          heal: () async {
            heals++;
            return LiveSyncHealOutcome.running;
          },
        )..start();
        draw(replay);
        backstop.stop();
        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(hours: 6));
        expect(heals, 0);

        backstop
          ..start()
          ..start();
        draw(replay);
        expect(
          async.pendingTimers,
          hasLength(1),
          reason: 'start is idempotent',
        );
        crossExpecting(
          async,
          draw(replay),
          () => heals,
          reason: 'the second start re-draws, it does not add a timer',
        );
        backstop.stop();
      });
    });
  });

  group('a logout ends what the shell built for the identity', () {
    test('MapShell.identityEnded: a logout or another identity ends it; a '
        'first resolution or a reload of the same one does not', () {
      expect(MapShell.identityEnded(before: 'aa', after: null), isTrue);
      expect(MapShell.identityEnded(before: 'aa', after: 'bb'), isTrue);
      expect(MapShell.identityEnded(before: null, after: 'aa'), isFalse);
      expect(MapShell.identityEnded(before: 'aa', after: 'aa'), isFalse);
      expect(MapShell.identityEnded(before: null, after: null), isFalse);
    });

    test('the identity listener drops the re-subscriber, whose running set '
        "holds the previous identity's circles", () {
      // MapShell is not disposed on logout, so without this the next
      // identity's first delta diffs against the previous identity's circles
      // and unsubscribes them on its own session.
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final arms = conditionalArms(
        source,
        className: '_MapShellState',
        method: 'initState',
        conditionContains: 'identityEnded',
      );
      expect(arms, hasLength(1));
      expect(arms.single.then, contains('_forgetLiveSyncInstall()'));
      final forget = methodSource(
        source,
        className: '_MapShellState',
        method: '_forgetLiveSyncInstall',
      );
      expect(forget, contains('_liveSyncResubscriber?.dispose()'));
      expect(forget, contains('_liveSyncResubscriber = null'));
      expect(forget, contains('_liveSyncCirclesSub?.close()'));
      expect(forget, contains('_liveSyncCirclesSub = null'));
    });
  });

  group('the live-sync install and first start are retryable', () {
    late String source;

    setUpAll(() {
      source = File('lib/src/pages/map_shell.dart').readAsStringSync();
    });

    test('startup no longer calls the engine start directly', () {
      // Every start must go through the re-subscriber's serialized chain, or
      // two of them can race the one engine — a second live
      // `AccountDeviceSession` over one MLS database (Security Rule 14).
      expect(
        source.contains('_liveSync!.start('),
        isFalse,
        reason: 'a direct start outside `ensureRunning`/`_fullRestart` is not '
            'serialized against the self-heal or a delta apply',
      );
      expect(
        RegExp(r'\.start\(groups:').hasMatch(source),
        isFalse,
        reason: 'same, in any shape',
      );
    });

    test('the first start goes through the self-heal', () {
      expect(
        source,
        contains('Future<void> _startLiveSync() => _healBackstop.heal();'),
        reason: 'the heal is the one start path; startup uses it THROUGH the '
            'backstop, so a failed first start is counted and retried on the '
            'same cadence as every later one, and the interval is re-drawn '
            "from the first attempt's outcome (`LiveSyncHealBackstop`, tested "
            'on a fake clock in the group above)',
      );
      expect(
        source.replaceAll(RegExp(r'\s+'), ' '),
        contains(
          '_healBackstop = LiveSyncHealBackstop( '
          'heal: _healLiveSyncIfStopped, );',
        ),
        reason: 'the backstop must heal through the one gated door',
      );
    });

    test('the heal installs the re-subscriber instead of giving up on null',
        () {
      // THE defect: the re-subscriber used to be installed only AFTER a
      // successful start, so one transient failure at launch left the field
      // null — which makes `_healLiveSyncIfStopped` return immediately forever
      // and `resumeAfterBackground()` a no-op against a null engine. Live
      // receive was gone for the rest of the process.
      final start = source.indexOf(
        'Future<LiveSyncHealOutcome> _healLiveSyncIfStopped() async {',
      );
      expect(start, isNonNegative);
      final body = source.substring(start, source.indexOf('\n  //', start));
      expect(
        body.contains('await _ensureLiveSyncInstalled()'),
        isTrue,
        reason: 'the heal must re-attempt the install, not return on a null '
            're-subscriber',
      );
      expect(
        body,
        contains(
          'if (resubscriber == null) return LiveSyncHealOutcome.failed;',
        ),
        reason: 'a null re-subscriber must still count a failure and back off, '
            'never silently succeed or stand down without one',
      );
    });

    test('the heal repairs a PAUSED engine too, which ensureRunning cannot '
        'see', () {
      // `ensureRunning` returns TRUE for a paused engine — `isRunning` is
      // `!shutdown && !wedged`, and a pause is neither — so the heal used to
      // report success over an engine holding no REQ and no socket. Since the
      // pause branch closes on EVERY iOS background pause, a resume whose one
      // re-anchor attempt failed lands here every time, and this is the only
      // periodic thing that runs while the app is on screen.
      final args = namedArgumentsOf(
        source,
        className: '_MapShellState',
        method: '_healLiveSyncIfStopped',
        constructed: 'reanchorPausedEngine',
      );
      expect(
        args['engine'],
        'ref.read(subscriptionServiceProvider)',
        reason: 'the same singleton the resume re-anchors',
      );
      expect(
        args['foregrounded'],
        'appIsResumed()',
        reason: 'a re-anchor while the app is AWAY puts a standing REQ back '
            'between bursts (R14); the timer can outlive a pause because '
            '`_startLiveSync` re-arms it from its own completion. The STRICT '
            'read, the one the engine is handed as its foreground claim: '
            '`appForegroundProvider` answers yes for `inactive` and for an '
            'unset lifecycle, and a re-anchor is a foreground open',
      );
      expect(
        args['lastReanchorAt'],
        '_lastReanchorAt',
        reason: 'the SAME clock the resume stamps, which is what stops the '
            'two spending two pool reconnects and two 96 h `#p` replays on '
            'one repair',
      );
      expect(
        assignmentsTo(
          source,
          className: '_MapShellState',
          method: '_healLiveSyncIfStopped',
          target: '_lastReanchorAt',
        ),
        ['_lastReanchorAt = at'],
        reason: 'an unrecorded re-anchor leaves the resume free to repeat it, '
            'and repeats it itself on the next tick',
      );
    });

    test('a heal joins the re-anchor an earlier heal left parked', () {
      // The behavioural proof is in map_shell_burst_wiring_test.dart; this
      // ties it to production. Past `healDeadline` heals overlap, 90 s or more
      // apart and so past the 60 s throttle, and each one used to queue a full
      // re-anchor behind the held lifecycle lock.
      final body = methodSource(
        source,
        className: '_MapShellState',
        method: '_healLiveSyncIfStopped',
      );
      expect(
        body,
        contains(
          '_healReanchorFlight.run(() => MapShell.reanchorPausedEngine(',
        ),
      );
      expect(
        body,
        isNot(contains('SingleFlight')),
        reason: 'a latch built per heal latches nothing',
      );
    });

    test('concurrent installs are single-flighted through the latch', () {
      // The behavioural proof is the `SingleFlight` group above; this is what
      // ties it to production. Two installs would build two re-subscribers
      // over one engine and leak the loser's circles listener.
      final start = source.indexOf(
        'Future<LiveSyncResubscriber?> _ensureLiveSyncInstalled() {',
      );
      expect(start, isNonNegative);
      final body = source.substring(start, source.indexOf('\n  ///', start));
      expect(
        body.contains('_installFlight.run(_installLiveSync)'),
        isTrue,
        reason: 'the install must go through the latch',
      );
      expect(
        body.contains('await '),
        isFalse,
        reason: 'this method must not await before the latch is set, or two '
            'callers slip past it — the latch is only a lock because every '
            'caller reaches it synchronously',
      );
      // Exactly one listener install, so a second run could not leak one.
      expect(
        '_liveSyncCirclesSub = ref.listenManual'.allMatches(source).length,
        1,
        reason: 'a second listener install site would reintroduce the leak the '
            'latch prevents',
      );
    });

    test('the re-subscriber is built from the circle snapshot alone', () {
      // It has to exist BEFORE any session does, because it is what performs
      // the first start.
      final start = source.indexOf(
        'Future<LiveSyncResubscriber?> _installLiveSync() async {',
      );
      expect(start, isNonNegative);
      final body = source.substring(start, source.indexOf('\n  ///', start));
      expect(body.contains('_liveSyncResubscriber = resubscriber'), isTrue);
      expect(body.contains('initialCircles: circles,'), isTrue);
      expect(
        body.contains('_liveSyncCirclesSub = ref.listenManual'),
        isTrue,
        reason: 'the circles listener is installed with it, so a mid-session '
            'circle-set change re-anchors even if no session ever started',
      );
    });

    test('the heal refuses to start an engine the build compiled out', () {
      // The rollback configuration's whole promise is that no live-sync engine
      // is ever started, and two of the heal's callers reach it without
      // consulting the flag: `_onResumed` heals AHEAD of its own debounce, and
      // the R1 consent edge heals from a PAUSED process. Ungated, a
      // `HAVEN_LIVE_SYNC=false` build therefore stood up a re-subscriber and a
      // live session on any `resumed` dispatch — an app switch, a shade pull, a
      // lock-screen check — putting long-lived REQs on the relays of the one
      // build whose point is that it has none.
      //
      // Read off the AST rather than the text, and SCOPED to this method.
      // Both halves are load-bearing. `conditionalArms` visits `IfStatement`
      // nodes and refuses to walk comments, so neither prose describing the
      // gate nor a string literal spelling it can satisfy this; and the file
      // holds other reads of the same flag, so a file-wide needle would go
      // on passing with the heal's own gate deleted.
      final gate = conditionalArms(
        source,
        className: '_MapShellState',
        method: '_healLiveSyncIfStopped',
        conditionContains: 'liveSyncEnabled',
      );
      expect(
        gate,
        hasLength(1),
        reason: 'exactly one flag gate — none is the defect, and a second one '
            'makes every assertion below about whichever came first',
      );
      expect(gate.single.condition.toSource(), '!liveSyncEnabled');
      expect(
        gate.single.then,
        'return LiveSyncHealOutcome.stoodDown;',
        reason: 'the flag-off arm must LEAVE the method — as a heal that '
            'stood down, which counts no failure — not fall through to a '
            'narrower branch that still installs or starts something',
      );
      expect(
        gate.single.orElse,
        isNull,
        reason: 'an else arm puts work on the flag-off path, which is the one '
            'path that must do none',
      );

      // …and it has to come FIRST, because the install is itself an effect: it
      // builds a `LiveSyncResubscriber` and registers a `circlesProvider`
      // listener in a build that owns neither.
      final body = methodSource(
        source,
        className: '_MapShellState',
        method: '_healLiveSyncIfStopped',
      );
      final gateAt = body.indexOf('!liveSyncEnabled');
      final installAt = body.indexOf('_ensureLiveSyncInstalled()');
      // Anti-vacuity before the comparison, because `-1 < n` passes: a needle
      // that quietly stopped matching would otherwise let this report an
      // ordering it never read — a guard green over a violated invariant.
      expect(gateAt, isNonNegative, reason: 'the gate must be in the body');
      expect(
        installAt,
        isNonNegative,
        reason: 'the install must still be here — the heal is also the FIRST '
            'start, so a body with no install has nothing left to gate',
      );
      expect(
        gateAt,
        lessThan(installAt),
        reason: 'the flag gate must precede the install, or a flag-off build '
            'builds a LiveSyncResubscriber and starts a session on resume — '
            'the rollback path running the plane its rollback removes',
      );
    });

    test('that one door is the only way to a start, so gating it suffices', () {
      // Why the gate belongs at the door and not at the two ungated call sites:
      // `ensureRunning` is the only thing in the shell that can bring a session
      // up, and it is reached from exactly ONE place — inside the gated method.
      // That is what turns "the heal is gated" into "no engine starts", and it
      // is what makes a future fifth caller covered for free.
      expect(
        methodSource(
          source,
          className: '_MapShellState',
          method: '_healLiveSyncIfStopped',
        ).contains('ensureRunning()'),
        isTrue,
        reason: 'the start must live INSIDE the gated method',
      );
      expect(
        RegExp(r'\.ensureRunning\(\)').allMatches(source).length,
        1,
        reason: 'a second call site would start an engine the flag gate never '
            'saw. The doc comments here name it in backticks without the call '
            'parentheses, which is what keeps this a count of code',
      );
    });
  });

  group('resume repairs before the debounce', () {
    late String resumeBody;

    setUpAll(() {
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _onResumed() async {');
      expect(start, isNonNegative, reason: '_onResumed must exist');
      // Bounded at the debounce's early return: everything asserted below has
      // to happen BEFORE it, so slicing there is what makes "before the
      // debounce" checkable rather than merely "somewhere in the method".
      final debounce = source.indexOf('if (!resumeExtrasDue()) return;', start);
      expect(debounce, greaterThan(start), reason: 'the debounce must exist');
      resumeBody = source.substring(start, debounce);
    });

    test('the engine re-anchor runs before the debounce', () {
      // The engine re-anchor is the only repair that recovers a REQ a relay
      // ended with `CLOSED`, and it used to sit AFTER the 30 s debounce — so
      // the glance pattern the debounce exists to absorb (shade pull,
      // lock-screen check, app-switcher peek) was exactly what kept it from
      // running. A user reopening the app BECAUSE peers had stopped appearing
      // routinely got no repair at all.
      //
      // THIS USED TO NAME `resumeAfterBackground()` DIRECTLY, and is updated
      // rather than relaxed: the resume no longer calls the engine method
      // itself, because a re-anchor issued into a burst that is still running
      // is undone by the `pauseSubscriptions()` that burst is about to take.
      // `reanchorOnResume` is that same repair plus the ordering that makes it
      // stick, so the promise here — "the resume re-anchors, ahead of the
      // debounce" — is unchanged and still fails when it breaks.
      expect(resumeBody.contains('MapShell.reanchorOnResume('), isTrue);
      expect(
        resumeBody.contains('engine.resumeAfterBackground()'),
        isFalse,
        reason: 'a direct call re-anchors INTO the race instead of behind it',
      );
    });

    test('but never unthrottled — it goes through its own guard', () {
      // Ahead of the debounce it would otherwise run on EVERY glance, and a
      // re-anchor is not cheap: it reconnects the pool and re-issues every REQ
      // including the inbox one, which asks for 96 hours of gift wraps, each
      // costing a secret materialisation and an FFI NIP-59 unwrap.
      final call = resumeBody.indexOf('MapShell.reanchorOnResume(');
      final guard = resumeBody.indexOf('MapShell.shouldReanchorOnResume(');
      expect(guard, isNonNegative, reason: 'the throttle must exist');
      expect(
        guard,
        lessThan(call),
        reason: 'the guard has to gate the call, not follow it',
      );
      expect(
        resumeBody.contains('_lastReanchorAt = resumeAt'),
        isTrue,
        reason: 'a guard that never records the attempt never throttles',
      );
    });

    test('the handoff-window poison is dropped between the handoff end and '
        'the heal', () {
      // Ordering is the contract. The handoff must end first (every open fails
      // closed while it holds), then the possibly-poisoned provider state is
      // dropped, and only then does anything read it again.
      final endHandoff = resumeBody.indexOf('_endMlsSessionHandoff()');
      final invalidate = resumeBody.indexOf('_invalidateHandoffWindowPoison()');
      final heal = resumeBody.indexOf('_healBackstop.heal()');
      expect(endHandoff, isNonNegative);
      expect(invalidate, greaterThan(endHandoff));
      expect(heal, greaterThan(invalidate));
    });

    test('circlesProvider is always re-read, because it hides its failures',
        () {
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      const signature = 'void _invalidateHandoffWindowPoison() {';
      final start = source.indexOf(signature);
      expect(start, isNonNegative);
      final body = source.substring(start, source.indexOf('\n  }', start));
      // Anchored at the method's OPENING BRACE, not merely "somewhere in the
      // body": an earlier version of this assertion passed with the call
      // wrapped in `if (…hasError)`, which is precisely the bug — a poisoned
      // `[]` is cached as a SUCCESS, so `hasError` is false and the sweep would
      // never fire for the one provider that needs it most.
      final afterBrace = body.substring(signature.length);
      expect(
        RegExp(r'^\n    ref\.invalidate\(circlesProvider\);')
            .hasMatch(afterBrace),
        isTrue,
        reason: 'the circlesProvider invalidate must be the first statement of '
            'the method and unconditional: it swallows EVERY failure to `[]` '
            'and caches it as a successful answer, so a poisoned read is '
            'undetectable after the fact',
      );
      expect(body.contains('inboxRelaysProvider'), isTrue);
      expect(body.contains('relayPreferencesServiceProvider'), isTrue);
    });
  });

  group('pause cancels the heal backstop before the handoff', () {
    test('the cancel is the first statement of _onPaused', () {
      // Same reason `_onDetached` documents: a heal tick landing mid-pause
      // restarts the engine while the Android branch is stopping it to hand
      // the MLS session over, leaving a FRESH session holding the Rule-14
      // guard the foreground service is waiting for. `_handOffMlsSession` is
      // awaited, so cancelling after it leaves the whole handoff window open.
      final source = File('lib/src/pages/map_shell.dart').readAsStringSync();
      final start = source.indexOf('Future<void> _onPaused() async {');
      expect(start, isNonNegative);
      final body = source.substring(start, source.indexOf('\n  ///', start));
      final cancel = body.indexOf('_healBackstop.stop()');
      final handoff = body.indexOf('_handOffMlsSession(');
      final readToggle = body.indexOf('ref.read(backgroundSharingProvider)');
      expect(cancel, isNonNegative, reason: 'the cancel must still be here');
      expect(handoff, greaterThan(cancel));
      expect(
        readToggle,
        greaterThan(cancel),
        reason: 'nothing may run before it — it is the first statement',
      );
    });
  });

  group('the restart budget is derived, not chosen', () {
    test("it is the engine's own bound on a stop + start", () {
      // Six lifecycle ops at 10 s (three in `stop_inner`, retried once) plus
      // the 5 s subscribe connect wait — see `kLiveSyncRestartBudget`. The
      // Rust mirrors are pinned by
      // `scripts/ci/check_live_sync_restart_budget.sh`.
      expect(kLiveSyncRestartBudget, const Duration(seconds: 65));
    });

    test('the heal deadline leaves a restart and a re-anchor their time', () {
      // A healthy heal past its deadline would be counted a failed restart
      // and back the next tick off for nothing.
      expect(LiveSyncHealBackstop.healDeadline, kLiveSyncRestartBudget * 2);
    });

    test('it expires before the heal backstop could tick again', () {
      // The backstop re-arms from the heal's completion, so a bound longer
      // than the shortest interval would stretch the cadence rather than
      // bound it.
      expect(
        kLiveSyncRestartBudget,
        lessThan(const Duration(seconds: LiveSyncHealBackstop.minSecs)),
        reason: 'the heal jitter floor',
      );
    });
  });
}
