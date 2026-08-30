/// Guards the gates around the MLS session reclaim.
///
/// `forceReleaseLiveSession` stops the process-global live-sync engine. Against
/// a LIVE main isolate that engine is the main isolate's own: the event stream
/// ends, nothing restarts it (`NostrSubscriptionService` registers no `onDone`),
/// and the Rule-14 guard is still held by the main isolate's `CircleManagerFfi`
/// — so the reclaim destroys live location receive and frees nothing. The call
/// is only safe once the main isolate has been shown to be gone.
///
/// The safety property is therefore ORDER, not merely presence: every gate must
/// run BEFORE the destructive call. A behavioural test cannot reach this code
/// (it needs the Rust bridge, a foreground service, and a second isolate), so
/// these assert over the source — the same approach the disclosure gate uses.
/// They are written to fail if a gate is deleted, weakened, or reordered.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String taskSource;
  late String cycleBody;
  late String reclaimBody;

  setUpAll(() {
    taskSource = File(
      'lib/src/services/background_location_task.dart',
    ).readAsStringSync();

    // Slice the two regions the assertions reason about, so an occurrence
    // elsewhere in the file (a doc comment, an unrelated method) can never
    // satisfy an ordering claim about these bodies.
    final reclaimStart = taskSource.indexOf(
      'Future<bool> _attemptSessionReclaim()',
    );
    expect(
      reclaimStart,
      isNonNegative,
      reason: '_attemptSessionReclaim must exist; if it was renamed, update '
          'these guards rather than deleting them',
    );
    final reclaimEnd = taskSource.indexOf(
      'Future<void> _publishCycle(',
      reclaimStart,
    );
    expect(reclaimEnd, isNonNegative);
    reclaimBody = taskSource.substring(reclaimStart, reclaimEnd);
    cycleBody = taskSource.substring(reclaimEnd);
  });

  group('the reclaim has exactly one call site', () {
    /// Every shape in which a file can get hold of the destructive call.
    ///
    /// A bare `contains('forceReleaseLiveSession(')` is NOT enough, and the gap
    /// was live: the UI isolate's route is wired as a TEAR-OFF
    /// (`forceReleaseLiveSession: forceReleaseLiveSession,`) with no
    /// parenthesis anywhere, so a whole second route to the lever was added and
    /// this guard — the guard whose entire job is to notice that — stayed
    /// green. Matching the identifier followed by any of `( , : )` covers the
    /// call, the tear-off, the named argument and the parameter declaration,
    /// and deliberately has no leading word boundary so the foreground
    /// service's `_forceReleaseLiveSession(` wrapper is caught by the same
    /// pattern. The `;` is not decoration either: `final probe =
    /// forceReleaseLiveSession;` is a complete route with neither a
    /// parenthesis nor a comma, and it stayed green without it.
    final routeToTheLever = RegExp(r'forceReleaseLiveSession\s*[(,:;)]');

    /// The files allowed to reach it, each with the reason it is allowed.
    ///
    /// Asserted as a SET rather than a count: a count answers "how many", which
    /// a swap of one sanctioned file for an unsanctioned one leaves unchanged.
    const sanctioned = <String>{
      // The background isolate's own reclaim, behind the liveness probe and
      // the gates asserted below.
      'lib/src/services/background_location_task.dart',
      // The UI isolate's wiring: the tear-off is injected into
      // NostrCircleService here and NOWHERE else, so the background isolate's
      // own circle service (built with `withInjectedManager`) cannot reach it.
      'lib/src/providers/service_providers.dart',
      // The UI isolate's consumer, behind the handover-verdict and
      // registry-re-read gates asserted below.
      'lib/src/services/nostr_circle_service.dart',
    };

    test('only the sanctioned files can reach forceReleaseLiveSession', () {
      final hits = <String>{};
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Skip the generated bindings, which necessarily declare it.
        if (entity.path.contains('/rust/')) continue;
        if (routeToTheLever.hasMatch(entity.readAsStringSync())) {
          hits.add(entity.path);
        }
      }
      expect(
        hits,
        sanctioned,
        reason: 'every route to this call needs its own complete set of gates '
            '— it stops the live-sync engine, and against an isolate that is '
            'actually alive that destroys live receive and frees nothing. A '
            'new file here means a new set of gates nobody has written.',
      );
    });

    test('the only call site is inside the gated helper', () {
      expect(
        reclaimBody.contains('forceReleaseLiveSession('),
        isTrue,
        reason: 'the destructive call must live behind the gates, not in the '
            'publish cycle or onStart',
      );
      expect(
        cycleBody.contains('forceReleaseLiveSession('),
        isFalse,
        reason: 'the publish cycle must go through _attemptSessionReclaim',
      );
    });
  });

  group('the destructive call is properly ordered', () {
    late int releaseAt;

    setUp(() {
      // The destructive call is routed through `_forceReleaseLiveSession`
      // (a thin wrapper that consults `overrideForceReleaseLiveSession` in
      // tests, defaulting to the real FFI call), not the bare FFI name — see
      // `background_location_task.dart`. The literal substring
      // `forceReleaseLiveSession(` still appears (as a suffix of the wrapper
      // name), which is what keeps the "one call site in lib/" check above
      // honest without a separate update.
      releaseAt = reclaimBody.indexOf('await _forceReleaseLiveSession(');
      expect(releaseAt, isNonNegative);
    });

    test('the pure gates are evaluated, and their verdict is acted on', () {
      // The gate LOGIC is covered behaviourally in
      // session_reclaim_decision_test.dart. What only a source check can add is
      // that the caller actually consults it and declines on a non-proceed
      // verdict — a call whose result was computed and dropped would pass any
      // amount of unit testing of the function itself.
      final at = reclaimBody.indexOf('evaluateSessionReclaimGates(');
      expect(at, isNonNegative);
      expect(at, lessThan(releaseAt));
      expect(
        reclaimBody.contains(
          'if (decision != SessionReclaimDecision.proceed) {',
        ),
        isTrue,
        reason: 'the verdict must gate the call, not merely be computed',
      );
      // The decline must actually return. A source scan that only checked for
      // the token would survive this `return` being deleted.
      final declineAt = reclaimBody.indexOf(
        'if (decision != SessionReclaimDecision.proceed) {',
      );
      expect(
        reclaimBody.substring(declineAt, declineAt + 220),
        contains('return false;'),
      );
    });

    test('the rate limit is consumed BEFORE the probe, not after', () {
      // The defect this pins: recording the attempt only on the reclaim path
      // meant an "alive" verdict never advanced the limit. That is the normal
      // steady state while the app is backgrounded, so the probe fired on every
      // 72-second tick — hundreds of independent chances for a GC pause to look
      // like death, instead of the handful the backoff is meant to allow.
      final write = reclaimBody.indexOf(
        'setInt(kBackgroundSessionReclaimAtMsKey',
      );
      final probe = reclaimBody.indexOf('mainIsolateIsAlive(');
      expect(write, isNonNegative);
      expect(probe, isNonNegative);
      expect(
        write,
        lessThan(probe),
        reason: 'a declined attempt must still consume the limit',
      );
      expect(write, lessThan(releaseAt));
    });

    test('a late reply aborts the reclaim even after both probes elapse', () {
      // Both probes timing out is not the same as nothing ever answering.
      final at = reclaimBody.indexOf('sawRecentReply');
      expect(
        at,
        isNonNegative,
        reason: 'a reply that lands after its own probe gave up is still proof '
            'the isolate is alive, and must abort the destructive step',
      );
      expect(at, lessThan(releaseAt));
    });

    test('the confirmation probe is spaced, not issued back-to-back', () {
      // Back-to-back probes observe one contiguous window, so a single
      // sustained stall satisfies both and the confirmation proves nothing.
      // The delay reads `livenessProbeGap` (a field defaulting to the real
      // `kLivenessProbeGap`, shortenable in tests — see
      // `background_location_task.dart`), not the bare constant.
      final firstProbe = reclaimBody.indexOf('mainIsolateIsAlive(');
      final gap = reclaimBody.indexOf('livenessProbeGap');
      final secondProbe = reclaimBody.indexOf(
        'mainIsolateIsAlive(',
        firstProbe + 1,
      );
      expect(gap, isNonNegative, reason: 'the probes must be separated');
      expect(firstProbe, lessThan(gap));
      expect(gap, lessThan(secondProbe));
    });

    test('each decision starts from a clean evidence round', () {
      // Without this, one old reply would suppress every later reclaim.
      final reset = reclaimBody.indexOf('resetRound()');
      final firstProbe = reclaimBody.indexOf('mainIsolateIsAlive(');
      expect(reset, isNonNegative);
      expect(reset, lessThan(firstProbe));
    });

    test('a dead verdict is confirmed by a second probe', () {
      // One silent window can be a garbage collection in a healthy isolate.
      expect(
        RegExp('mainIsolateIsAlive').allMatches(reclaimBody).length,
        greaterThanOrEqualTo(2),
        reason: 'acting on a single timeout makes transient jank sufficient to '
            'destroy a live session',
      );
      final firstProbe = reclaimBody.indexOf('mainIsolateIsAlive(');
      final secondProbe = reclaimBody.indexOf(
        'mainIsolateIsAlive(',
        firstProbe + 1,
      );
      expect(secondProbe, lessThan(releaseAt));
    });

    test('the guard is re-checked after probing', () {
      // The first query is seconds stale by the time the probes finish.
      //
      // Anchored on the literal `await _isSessionLive(` — not the bare
      // `isSessionLive` token — because the `_isSessionLive` wrapper (the
      // test-seam indirection over the real FFI call) sits textually between
      // `_attemptSessionReclaim` and `_publishCycle`, inside this same
      // `reclaimBody` slice, and donates three matches of the bare token on
      // its own: its doc comment references `[isSessionLive]`, its own
      // signature is `_isSessionLive(`, and its body makes a bare,
      // non-`await`-prefixed call to `isSessionLive(`. None of those three is
      // preceded by `await _isSessionLive(`, so counting that longer anchor
      // — as `releaseAt` above does for `_forceReleaseLiveSession` — still
      // finds exactly the two real call sites (the initial guard check and
      // the post-probe re-check) and cannot be satisfied by the wrapper's own
      // text.
      expect(
        'await _isSessionLive('.allMatches(reclaimBody).length,
        greaterThanOrEqualTo(2),
        reason: 'a guard released while probing means there is nothing to '
            'reclaim — open instead of tearing anything down',
      );
    });
  });

  group('acquiring a session is not the same as reclaiming one', () {
    // The bug this pins. The reclaim DECLINES when the guard is free
    // (`guardNotHeld`) — correctly, since there is nothing to reclaim. But the
    // normal path to owning a session is exactly that free case: the foreground
    // hands it over at pause. With the reclaim wired as the only recovery, the
    // service declined to open a database sitting available, and background
    // publishing stayed dead through the very handoff meant to enable it.
    late String ensureBody;

    setUpAll(() {
      final at = taskSource.indexOf('Future<bool> _ensureSession() async {');
      expect(at, isNonNegative, reason: '_ensureSession must exist');
      ensureBody = taskSource.substring(
        at,
        taskSource.indexOf('\n  /// Tries to recover', at),
      );
    });

    test('the cycle goes through _ensureSession, not straight to a reclaim', () {
      // Anchored on `await _ensureSession()` — not the bare `_ensureSession()`
      // token — because `cycleBody` runs unbounded to the end of the file and
      // so also contains `ensureSessionForTest` (the test-only seam near the
      // bottom of the class), whose body makes a non-`await`-prefixed
      // `return _ensureSession();` call. The bare token would find that seam
      // just as happily as the real orchestration call.
      final at = cycleBody.indexOf('await _ensureSession()');
      expect(at, isNonNegative);
      expect(
        cycleBody.contains('!await _attemptSessionReclaim()'),
        isFalse,
        reason: 'the reclaim must be an escalation, never the only route',
      );
    });

    test('a FREE guard leads to a plain open', () {
      final query = ensureBody.indexOf('isSessionLive(');
      final open = ensureBody.indexOf('_openCircleManager()');
      expect(query, isNonNegative);
      expect(
        open,
        isNonNegative,
        reason: 'the post-handoff case needs an open, not a reclaim',
      );
      expect(
        query,
        lessThan(open),
        reason: 'query first — it is cheap and decides which path applies',
      );
      expect(
        ensureBody.contains('_repairSharingServices()'),
        isTrue,
        reason: 'an opened manager with no services still cannot publish; the '
            'repair helper wires them and rebuilds any that bring-up lost',
      );
    });

    test('a HELD guard escalates to the reclaim', () {
      final at = ensureBody.indexOf('_attemptSessionReclaim()');
      expect(at, isNonNegative);
      expect(
        RegExp(r'if\s*\(guardHeld\)').hasMatch(ensureBody),
        isTrue,
        reason: 'only a held guard may escalate',
      );
    });

    test('an unanswerable query neither opens nor escalates', () {
      // "Cannot tell" must not become "free" (open blind) or "held" (escalate
      // to a destructive path on no evidence).
      final at = ensureBody.indexOf('session query failed');
      expect(at, isNonNegative);
      expect(
        ensureBody.substring(at, at + 120),
        contains('return false'),
      );
    });
  });

  group('the reclaim runs only where the foreground is known idle', () {
    test('it is invoked after the foreground-active gate', () {
      // Anchored on `await _ensureSession()`, for the same reason as above:
      // `cycleBody` is unbounded to the end of the file, and the bare token
      // is also satisfied by `ensureSessionForTest`'s non-`await`-prefixed
      // `return _ensureSession();` near the bottom of the class — which,
      // being defined long after this gate, would make a DELETED real call
      // still read as "correctly ordered after the gate" instead of
      // "missing".
      final gateAt = cycleBody.indexOf('if (foregroundActive) {');
      final reclaimAt = cycleBody.indexOf('await _ensureSession()');
      expect(gateAt, isNonNegative);
      expect(
        reclaimAt,
        isNonNegative,
        reason: 'the publish cycle must attempt recovery, or a missing manager '
            'is permanent until the app is relaunched',
      );
      expect(
        gateAt,
        lessThan(reclaimAt),
        reason: 'running recovery before this gate could tear down a session '
            'the visible UI is actively using',
      );
    });

    test('onStart does not reclaim', () {
      final onStartAt = taskSource.indexOf('Future<void> onStart(');
      final onRepeatAt = taskSource.indexOf('void onRepeatEvent(');
      expect(onStartAt, isNonNegative);
      expect(onRepeatAt, greaterThan(onStartAt));
      expect(
        taskSource
            .substring(onStartAt, onRepeatAt)
            .contains('_attemptSessionReclaim'),
        isFalse,
        reason: 'onStart runs regardless of foreground state, so a reclaim '
            'there could stop the engine of a live, visible UI',
      );
    });

    test('a failed reclaim aborts the cycle rather than publishing', () {
      // Asserted structurally rather than as one exact statement: the previous
      // version matched a whole line verbatim, so a reformat or an equivalent
      // rewrite would have failed CI without any safety property changing.
      // Anchored on `await _ensureSession()` for the same reason as the two
      // tests above — the bare token is also satisfied by the unrelated,
      // non-`await`-prefixed call inside `ensureSessionForTest`.
      final at = cycleBody.indexOf('await _ensureSession()');
      expect(at, isNonNegative);
      expect(
        cycleBody.substring(at, at + 60),
        contains('return'),
        reason: 'without the early return the cycle would dereference a null '
            'manager after an unsuccessful recovery',
      );
    });

    test('a manager with unwired services is repaired, not reclaimed', () {
      // The isolate already owns the session, so a reclaim is both unnecessary
      // and destructive. Before this path existed, an onStart that opened the
      // manager and then failed to build the relay service left the isolate
      // holding the Rule-14 guard forever: recovery keyed off a null manager,
      // which this state does not have.
      final at = cycleBody.indexOf('_repairSharingServices()');
      expect(
        at,
        isNonNegative,
        reason: 'a half-initialised isolate must be able to finish wiring',
      );
      expect(
        cycleBody.substring(at, at + 60),
        contains('return'),
      );
    });
  });

  group('a failed open does not strip the isolate of its services', () {
    test('onStart wires the sharing services through a reusable helper', () {
      // A manager open that threw out of onStart used to skip the relay and
      // location-sharing construction too, so a later recovery that rebuilt
      // only the manager still could not publish.
      expect(taskSource.contains('void _wireSharingServices()'), isTrue);
      expect(
        RegExp(r'_wireSharingServices\(\);').allMatches(taskSource).length,
        greaterThanOrEqualTo(2),
        reason: 'both onStart and the recovery path must wire the services; '
            'one call site means recovery leaves them null',
      );
    });

    test('the manager open swallows its own failure', () {
      final openAt = taskSource.indexOf('Future<void> _openCircleManager()');
      expect(openAt, isNonNegative);
      final openEnd = taskSource.indexOf('void _wireSharingServices()', openAt);
      expect(openEnd, isNonNegative);
      expect(
        taskSource.substring(openAt, openEnd).contains('on Object catch'),
        isTrue,
        reason: 'the open must not throw past its caller, or onStart aborts '
            'before building the services recovery depends on',
      );
    });
  });

  group('the UI isolate route is gated too', () {
    // The SECOND route to the same destructive call, added for C1: a Rule-14
    // guard held by this isolate's own live-sync engine after a stop that timed
    // out, which the foreground service's reclaim can never take (it probes the
    // main isolate, finds it alive, and correctly declines forever). Its gates
    // are different from the reclaim's — there is no liveness to infer, because
    // this isolate is deciding about itself — but they are gates all the same,
    // and they are the reason the file above is allowed to name the lever.
    late String eligibility;
    late String release;

    setUpAll(() {
      final src = File(
        'lib/src/services/nostr_circle_service.dart',
      ).readAsStringSync();

      final recoverAt = src.indexOf(
        'Future<bool> _recoverHeldSession(String dataDir) async {',
      );
      final releaseAt = src.indexOf(
        'Future<bool> _forceReleaseOrphanedSession(String dataDir) async {',
      );
      expect(
        recoverAt,
        isNonNegative,
        reason: 'the UI-isolate recovery must exist; if it was renamed, '
            'update these guards rather than deleting them',
      );
      expect(releaseAt, greaterThan(recoverAt));

      // Sliced so a mention in a doc comment elsewhere in this 1900-line file
      // can never satisfy an ordering claim about these two bodies.
      eligibility = src.substring(recoverAt, releaseAt);
      release = src.substring(
        releaseAt,
        src.indexOf('\n  /// Ensures the manager is initialized', releaseAt),
      );
    });

    test('only a timedOut handover reaches the lever', () {
      // `backgrounded` is the one that MUST never get through: it means the
      // pause-time handoff is working as designed and the foreground service
      // legitimately holds the session, so force-releasing would end the
      // user's background location sharing to satisfy a routine maintenance
      // tick. Asserted as an allow-list rather than a deny-list, so a verdict
      // added to `HandoverOutcome` later cannot quietly become eligible.
      final verdicts = RegExp(r'HandoverOutcome\.(\w+)')
          .allMatches(eligibility)
          .map((m) => m.group(1))
          .toSet();
      expect(
        verdicts,
        {'released', 'timedOut'},
        reason: 'a verdict compared here is a verdict that can route to the '
            'force-release; `backgrounded` would cost the user background '
            'sharing, and `stopFailed`/`notHeld` establish nothing about who '
            'holds the guard',
      );

      final gate = eligibility.indexOf(
        'if (outcome != HandoverOutcome.timedOut) return false;',
      );
      final call = eligibility.indexOf('_forceReleaseOrphanedSession(dataDir)');
      expect(gate, isNonNegative, reason: 'the verdict gate must be intact');
      expect(
        call,
        greaterThan(gate),
        reason: 'the gate must precede the call, not follow it',
      );
    });

    test('the registry is re-read immediately before the release', () {
      // The handover's own answer is a snapshot from BEFORE it stopped and
      // polled the service. Spending a call that stops the live-sync engine on
      // a stale reading is exactly the "destroys live receive and frees
      // nothing" case this whole file exists to prevent.
      final read = release.indexOf('await readRegistry(dataDir)');
      final declineIfFree = release.indexOf('if (!held) return false;');
      final call = release.indexOf('await forceRelease()');
      expect(read, isNonNegative, reason: 'the registry must be re-read');
      expect(declineIfFree, greaterThan(read));
      expect(
        call,
        greaterThan(declineIfFree),
        reason: 'a free guard must decline BEFORE the destructive call',
      );

      // Nothing awaited may sit between the decline and the call: an await
      // there is a window in which the answer can go stale again.
      final between = release.substring(declineIfFree, call);
      expect(
        between.contains('await'),
        isFalse,
        reason: 'the re-read must be immediately before the call; an await in '
            'between reintroduces the staleness it exists to close',
      );
    });

    test('an unanswerable registry is not read as a free guard', () {
      // Fail CLOSED in both directions: "cannot tell" must neither open blind
      // nor fire the lever.
      final read = release.indexOf('await readRegistry(dataDir)');
      final catchAt = release.indexOf('on Object catch', read);
      expect(catchAt, isNonNegative);
      // Bounded by the clause's own closing brace at method-body indentation —
      // a bare `indexOf('}')` stops at the first `${...}` interpolation inside
      // the log line and would read as "no return here" even when one follows.
      final clauseEnd = release.indexOf('\n    }', catchAt);
      expect(clauseEnd, greaterThan(catchAt));
      expect(
        release.substring(catchAt, clauseEnd),
        contains('return false'),
        reason: 'a query that cannot answer must decline, not proceed',
      );
    });

    test('neither half retries in a loop', () {
      // One shot. Looping would stop the foreground service (and this
      // isolate's engine) once per pass while making no progress against a
      // guard neither can reach.
      for (final body in <String>[eligibility, release]) {
        expect(
          RegExp(r'\b(while|for)\s*\(').hasMatch(body),
          isFalse,
          reason: 'the recovery must be attempted once per initialize',
        );
      }
    });
  });
}
