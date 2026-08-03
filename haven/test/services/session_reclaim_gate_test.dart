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
    test('forceReleaseLiveSession is called from one place in lib/', () {
      final hits = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Skip the generated bindings, which necessarily declare it.
        if (entity.path.contains('/rust/')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('forceReleaseLiveSession(')) hits.add(entity.path);
      }
      expect(
        hits,
        hasLength(1),
        reason: 'a second call site would need its own copy of every gate '
            'below; found: $hits',
      );
      expect(hits.single, endsWith('background_location_task.dart'));
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
      releaseAt = reclaimBody.indexOf('await forceReleaseLiveSession(');
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
      expect(
        RegExp('isSessionLive').allMatches(reclaimBody).length,
        greaterThanOrEqualTo(2),
        reason: 'a guard released while probing means there is nothing to '
            'reclaim — open instead of tearing anything down',
      );
    });
  });

  group('the reclaim runs only where the foreground is known idle', () {
    test('it is invoked after the foreground-active gate', () {
      final gateAt = cycleBody.indexOf('if (foregroundActive) {');
      final reclaimAt = cycleBody.indexOf('_attemptSessionReclaim()');
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
      final at = cycleBody.indexOf('_attemptSessionReclaim()');
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
}
