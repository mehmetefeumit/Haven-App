/// Behavioural proof of the Rule-14 session-reclaim orchestration in
/// [BackgroundLocationTaskHandler].
///
/// `session_reclaim_gate_test.dart` and `session_reclaim_decision_test.dart`
/// cover this machinery two other ways: the first pins the SOURCE TEXT of
/// `_ensureSession`/`_attemptSessionReclaim` (gate tokens appear, in order,
/// before the destructive call), and the second exhaustively tests the pure
/// decision function `evaluateSessionReclaimGates`. Neither exercises the
/// real method bodies against a scripted sequence of answers — a source scan
/// proves a gate's TOKEN is present, not that the branch it guards actually
/// runs and produces the right outcome, and the pure-function tests never
/// touch `_ensureSession`/`_attemptSessionReclaim` at all.
///
/// This file closes that gap using the `override*`/`liveness*` test seams on
/// [BackgroundLocationTaskHandler] (added alongside it) and
/// [BackgroundLocationTaskHandler.ensureSessionForTest], which is what makes
/// the otherwise-private `_ensureSession` reachable without the FFI-bound
/// identity load `onStart` requires — mirroring the existing
/// `staggerWaitForTest` seam for the same reason.
///
/// # What this still cannot prove
///
/// [BackgroundLocationTaskHandler.overrideCircleManager] takes a real
/// `CircleManagerFfi` — an FFI opaque handle with no fake construction
/// available in a host test — so with no identity manager and no overridden
/// manager, a "successful" reclaim in these tests still ends with no session
/// to publish through; every test here observes the DECISION machinery
/// (whether the destructive call runs, and in what order), not a publish. The
/// full "reclaims and then genuinely publishes" claim is proven at the FFI
/// boundary by `force_release_does_not_release_while_a_manager_handle_is_alive`
/// and `a_live_manager_is_visible_to_the_session_liveness_query`
/// (`rust_builder/src/api.rs`) — a released guard IS re-acquirable — and at
/// runtime by the `e2e-fgs-publish` lane, for the ORDINARY pause-time handoff.
/// No E2E lane currently drives a genuinely-killed main isolate through this
/// exact reclaim path (the one-off `p0-1-session-probe` workflow that answered
/// the underlying design question was deleted once its answer was recorded in
/// `docs/P0_1_FGS_SESSION_PLAN.md`); building one is out of this file's scope.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart' show ForceReleaseOutcomeFfi;
import 'package:haven/src/services/background_location_task.dart';
import 'package:haven/src/services/foreground_liveness_probe.dart'
    show kLivenessPongKey;
import 'package:shared_preferences/shared_preferences.dart';

/// Short enough that the "genuinely dead" cases below cost tens of
/// milliseconds, not the real 5 s + 3 s + 5 s production sequence.
const _shortTimeout = Duration(milliseconds: 30);
const _shortGap = Duration(milliseconds: 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// Builds a handler wired for the reclaim path: an identity (faked via the
  /// override, since `NostrIdentityManager` is FFI-only) and a real,
  /// channel-ready liveness probe running short timeouts.
  BackgroundLocationTaskHandler buildHandler({
    required bool Function({required String dataDir}) isSessionLive,
    ForceReleaseOutcomeFfi Function()? onForceRelease,
  }) {
    final handler = BackgroundLocationTaskHandler()
      ..overrideHasIdentity = true
      ..livenessChannelReady = (() => true)
      ..livenessProbeTimeout = _shortTimeout
      ..livenessProbeGap = _shortGap
      ..overrideIsSessionLive = (({required dataDir}) async {
        return isSessionLive(dataDir: dataDir);
      });
    if (onForceRelease != null) {
      handler.overrideForceReleaseLiveSession = () async => onForceRelease();
    }
    return handler;
  }

  test(
    'a genuinely dead foreground: the destructive call runs, but only after '
    'BOTH confirmation probes time out and the guard is re-checked',
    () async {
      final events = <String>[];
      final handler = buildHandler(
        // Held on every query: the initial `_ensureSession` check, the
        // reclaim's own initial check, AND the post-probe re-check.
        isSessionLive: ({required dataDir}) {
          events.add('query');
          return true;
        },
        onForceRelease: () {
          events.add('release');
          return ForceReleaseOutcomeFfi.drained;
        },
      );

      final stopwatch = Stopwatch()..start();
      // No reply is ever fed via onReceiveData — the probe genuinely times
      // out twice, exercising the real ping/timeout/gap protocol rather than
      // the "channel not ready" fast path.
      await handler.ensureSessionForTest(dataDir: 'test-data-dir');
      stopwatch.stop();

      expect(
        events,
        <String>['query', 'query', 'query', 'release'],
        reason: 'the destructive call must be the LAST thing that happens, '
            'strictly after the guard has been asked three times (the '
            'initial escalation check, the gate check, and the post-probe '
            're-check) — not merely present somewhere in the trace',
      );
      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(_shortTimeout * 2 + _shortGap),
        reason: 'a destructive reclaim must cost two real confirmation '
            'timeouts and the gap between them, not a shortcut',
      );
    },
  );

  test(
    'a foreground that answers the FIRST probe is never torn down',
    () async {
      final events = <String>[];
      // Counts `channelReady()` invocations — the FIRST thing
      // `mainIsolateIsAlive` does, before it registers a nonce or awaits
      // anything. A second probe existing is already pinned structurally by
      // `session_reclaim_gate_test.dart`; what only a real run can show is
      // that the SECOND one is never actually ISSUED when the first already
      // answered. Asserting this by elapsed wall-clock time would be a race
      // (a reply fed just before the mutated first check falls through can
      // still land inside the second probe's own — much longer — timeout and
      // produce the same "no release" outcome from the WRONG probe). This
      // counter is exact and immune to that.
      var channelReadyCalls = 0;
      // Completed synchronously inside `livenessChannelReady` below, which
      // `mainIsolateIsAlive` calls as its very first statement — before it
      // registers the probe's nonce or sends the ping, and with no `await`
      // in between. Awaiting this Completer therefore guarantees the
      // registration has happened by the time this test resumes: Dart does
      // not run a completed Completer's microtask continuation until the
      // current synchronous call stack (which includes that registration)
      // has finished unwinding. This replaces a fixed-delay sleep that only
      // happened to outrun `SharedPreferences.getInstance` + `.reload` + the
      // pure gate check + `.setInt` by construction, not by guarantee.
      final nonceRegistered = Completer<void>();
      final handler = buildHandler(
        isSessionLive: ({required dataDir}) {
          events.add('query');
          return true;
        },
        onForceRelease: () {
          events.add('release');
          return ForceReleaseOutcomeFfi.drained;
        },
      )
        ..livenessProbeTimeout = const Duration(seconds: 2)
        ..livenessChannelReady = (() {
          channelReadyCalls++;
          if (!nonceRegistered.isCompleted) nonceRegistered.complete();
          return true;
        });

      final resultFuture = handler.ensureSessionForTest(
        dataDir: 'test-data-dir',
      );
      // Wait for the probe to have registered its nonce and started
      // listening for a reply — a reply fed before that point is
      // indistinguishable from one for an unrelated, earlier round and is
      // correctly dropped (see ForegroundLivenessProbe.onData).
      await nonceRegistered.future;
      // The main isolate's real reply path: `onReceiveData` routes to the
      // probe exactly as production does. Nonce 1 is the first probe this
      // fresh handler's probe instance ever issues.
      handler.onReceiveData(<String, Object>{kLivenessPongKey: 1});

      final result = await resultFuture;

      expect(
        result,
        isFalse,
        reason: 'no manager and no identity means nothing to publish '
            'through even on the safe path — this asserts the DECISION, not '
            'a publish (see the file doc comment)',
      );
      expect(
        events,
        <String>['query', 'query'],
        reason: 'the two guard queries (escalation + gate check) still run, '
            'but the reply must stop the reclaim before it ever asks a '
            'second time or releases anything',
      );
      expect(
        channelReadyCalls,
        1,
        reason: 'a SECOND probe must never even be attempted once the first '
            'has proof of life — this is what a purely elapsed-time '
            'assertion cannot tell apart from "the second probe happened to '
            'catch the same reply instead"',
      );
    },
  );

  test(
    'the guard freeing itself between the probes and the re-check cancels '
    'the reclaim — no release is issued',
    () async {
      final events = <String>[];
      var queryCount = 0;
      final handler = buildHandler(
        isSessionLive: ({required dataDir}) {
          queryCount++;
          events.add('query');
          // Held for the first two queries (escalation, gate check); freed
          // by the third (the post-probe re-check).
          return queryCount < 3;
        },
        onForceRelease: () {
          events.add('release');
          return ForceReleaseOutcomeFfi.drained;
        },
      );

      final result = await handler.ensureSessionForTest(
        dataDir: 'test-data-dir',
      );

      expect(
        result,
        isFalse,
        reason: 'no manager and no identity means nothing to publish '
            'through — see the file doc comment',
      );
      expect(
        events,
        <String>['query', 'query', 'query'],
        reason: 'the guard freeing itself mid-probe must route to a plain '
            'open, never to the destructive release — reclaiming a slot '
            'nobody holds any more would achieve nothing and cost a real '
            'engine stop for free',
      );
    },
  );
}
