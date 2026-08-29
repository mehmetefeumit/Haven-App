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

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/services/live_sync_resubscriber.dart';

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
      // 7-day gift-wrap replays, each wrap costing a secret materialisation
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
      final start = source.indexOf('Future<void> _startLiveSync() async {');
      expect(start, isNonNegative, reason: '_startLiveSync must exist');
      final body = source.substring(start, source.indexOf('\n  /// ', start));
      expect(
        body.contains('_healLiveSyncIfStopped()'),
        isTrue,
        reason: 'the heal is the one start path; startup uses it so a failed '
            'first start is retried on the same backstop as every later one',
      );
      expect(
        body.contains('_rearmLiveSyncHealTimer()'),
        isTrue,
        reason: 'the backstop interval must be re-drawn from the first '
            "attempt's outcome, not left at the one armed before it",
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
        'Future<void> _healLiveSyncIfStopped() async {',
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
        RegExp(r'if \(resubscriber == null\) return').hasMatch(body),
        isFalse,
        reason: 'a null re-subscriber must still count a failure and back off, '
            'never silently succeed or bail without one',
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
      expect(
        body.contains('LiveSyncResubscriber.groupsForCircles(circles)'),
        isTrue,
      );
      expect(
        body.contains('_liveSyncCirclesSub = ref.listenManual'),
        isTrue,
        reason: 'the circles listener is installed with it, so a mid-session '
            'circle-set change re-anchors even if no session ever started',
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
      final debounce = source.indexOf('if (_resumeStopwatch.isRunning', start);
      expect(debounce, greaterThan(start), reason: 'the debounce must exist');
      resumeBody = source.substring(start, debounce);
    });

    test('the engine re-anchor runs before the debounce', () {
      // `resumeAfterBackground()` is the only repair that recovers a REQ a
      // relay ended with `CLOSED`, and it used to sit AFTER the 30 s debounce —
      // so the glance pattern the debounce exists to absorb (shade pull,
      // lock-screen check, app-switcher peek) was exactly what kept it from
      // running. A user reopening the app BECAUSE peers had stopped appearing
      // routinely got no repair at all.
      expect(resumeBody.contains('resumeAfterBackground()'), isTrue);
    });

    test('but never unthrottled — it goes through its own guard', () {
      // Ahead of the debounce it would otherwise run on EVERY glance, and a
      // re-anchor is not cheap: it reconnects the pool and re-issues every REQ
      // including the inbox one, whose `since` always asks for 7 days of gift
      // wraps, each costing a secret materialisation and an FFI NIP-59 unwrap.
      final call = resumeBody.indexOf('resumeAfterBackground()');
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
      final heal = resumeBody.indexOf('_healLiveSyncIfStopped()');
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
      final cancel = body.indexOf('_liveSyncHealTimer?.cancel()');
      final handoff = body.indexOf('_handOffMlsSession()');
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

    test('it expires before the heal backstop could tick again', () {
      // The backstop re-arms from the heal's completion, so a bound longer
      // than the shortest interval would stretch the cadence rather than
      // bound it.
      expect(
        kLiveSyncRestartBudget,
        lessThan(const Duration(seconds: 90)),
        reason: 'the heal jitter floor is 90 s (`_healMinSecs`)',
      );
    });
  });
}
