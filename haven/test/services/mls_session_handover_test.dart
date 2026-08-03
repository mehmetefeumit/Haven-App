/// Behavioural coverage for the UI isolate's recovery from a
/// foreground-service-held MLS guard.
///
/// The failure being recovered from is total and permanent: the service takes
/// the Rule-14 guard at a cold `onStart`, the UI's own initialisation retries
/// forever against it, and the user gets no circles, no map, no publishing and
/// no receiving until they toggle background sharing off or the process dies.
///
/// Every dependency is injected, so all of this runs without the plugin, the
/// Rust bridge, or a real service.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/mls_session_handover.dart';

void main() {
  /// Drives the handover with recorded calls and a scripted guard.
  ///
  /// [liveResponses] is consumed one entry per `isSessionLive` call; the last
  /// entry repeats, so a test only has to script the interesting prefix.
  Future<
    ({
      HandoverOutcome outcome,
      int stops,
      int restarts,
      int queries,
      Duration slept,
    })
  >
  run({
    required List<bool> liveResponses,
    bool backgroundSharingEnabled = true,
    bool stopThrows = false,
    bool restartThrows = false,
    Object? queryThrowsAfter,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    var queries = 0;
    var stops = 0;
    var restarts = 0;
    var slept = Duration.zero;

    final outcome = await requestSessionHandover(
      dataDir: '/data/haven',
      isSessionLive: (_) async {
        final i = queries++;
        if (queryThrowsAfter != null && i >= (queryThrowsAfter as int)) {
          throw Exception('query unavailable');
        }
        return liveResponses[i.clamp(0, liveResponses.length - 1)];
      },
      stopService: () async {
        stops++;
        if (stopThrows) throw Exception('stop failed');
      },
      restartService: () async {
        restarts++;
        if (restartThrows) throw Exception('restart failed');
      },
      backgroundSharingEnabled: backgroundSharingEnabled,
      timeout: timeout,
      pollInterval: const Duration(milliseconds: 250),
      // Virtual clock: no real waiting, but elapsed time is still accounted for
      // so the timeout is exercised rather than skipped.
      delay: (d) async => slept += d,
    );

    return (
      outcome: outcome,
      stops: stops,
      restarts: restarts,
      queries: queries,
      slept: slept,
    );
  }

  group('the guard is not held', () {
    test('nothing is stopped and nothing is restarted', () async {
      // A failure with a free guard is something a handover cannot fix — a
      // locked keyring, a full disk. Stopping the service would cost the user
      // background sharing for nothing.
      final r = await run(liveResponses: [false]);
      expect(r.outcome, HandoverOutcome.notHeld);
      expect(r.stops, 0, reason: 'the service must not be touched');
      expect(r.restarts, 0);
    });
  });

  group('the guard is held', () {
    test('the service is stopped and the release is observed', () async {
      // Held at the initial check, still held on the first poll, released on
      // the second — the realistic shape, since the guard is freed by the
      // service's onDestroy well after the stop call returns.
      final r = await run(liveResponses: [true, true, false]);
      expect(r.outcome, HandoverOutcome.released);
      expect(r.stops, 1);
      expect(
        r.queries,
        greaterThan(1),
        reason: 'the stop call returning is not evidence the guard is free — '
            'onDestroy drains an in-flight publish first',
      );
    });

    test('a guard that is never released times out rather than hanging', () async {
      final r = await run(
        liveResponses: [true],
        timeout: const Duration(seconds: 2),
      );
      expect(r.outcome, HandoverOutcome.timedOut);
      expect(
        r.slept,
        lessThanOrEqualTo(const Duration(seconds: 2)),
        reason: 'the wait must be bounded — this runs while the user is '
            'looking at a blank map',
      );
    });

    test('a failed stop is reported and not waited on', () async {
      final r = await run(liveResponses: [true], stopThrows: true);
      expect(r.outcome, HandoverOutcome.stopFailed);
      expect(
        r.slept,
        Duration.zero,
        reason: 'nothing was asked to release, so there is nothing to wait for',
      );
    });

    test('a query that starts failing is not read as a released guard', () async {
      // The dangerous direction: treating "cannot tell" as "free" would make
      // the caller retry the open against a guard that is still held, burning
      // its one attempt.
      final r = await run(liveResponses: [true], queryThrowsAfter: 1);
      expect(r.outcome, isNot(HandoverOutcome.released));
    });
  });

  group('the user setting is not changed by the recovery', () {
    test('the service is restarted when background sharing is on', () async {
      // Leaving it stopped would silently give the user less than they asked
      // for. The pause is bounded by the handover, not permanent.
      final r = await run(liveResponses: [true, false]);
      expect(r.restarts, 1);
    });

    test('it is restarted even when the guard never cleared', () async {
      // The recovery failing is no reason to leave background sharing off.
      final r = await run(
        liveResponses: [true],
        timeout: const Duration(seconds: 1),
      );
      expect(r.outcome, HandoverOutcome.timedOut);
      expect(r.restarts, 1);
    });

    test('it is NOT restarted when background sharing is off', () async {
      // Starting a location service the user has disabled would be a privacy
      // regression, not a recovery.
      final r = await run(
        liveResponses: [true, false],
        backgroundSharingEnabled: false,
      );
      expect(r.restarts, 0);
      expect(
        r.outcome,
        HandoverOutcome.released,
        reason: 'the handover itself still succeeds',
      );
    });

    test('a failed restart does not mask a successful handover', () async {
      final r = await run(liveResponses: [true, false], restartThrows: true);
      expect(
        r.outcome,
        HandoverOutcome.released,
        reason: 'the UI can open its session now, which is the point',
      );
    });
  });

  group('the service is asked to stop exactly once', () {
    test('polling does not re-issue the stop', () async {
      // A stop per poll would fight the restart and thrash the notification.
      final r = await run(
        liveResponses: [true, true, true, false],
      );
      expect(r.stops, 1);
    });
  });
}
