/// Behavioural coverage for the session-reclaim gates.
///
/// These exist because the companion `session_reclaim_gate_test.dart` scans
/// SOURCE TEXT, and a text scan can prove a gate's token appears before the
/// destructive call without proving the gate declines — it cannot see a `return`
/// removed from an `if` body, and it cannot see the comparison operator in the
/// rate limit at all. `evaluateSessionReclaimGates` was extracted so those
/// properties are testable directly.
///
/// What is at stake: authorising a reclaim stops the process-global live-sync
/// engine. If the main isolate is alive, that is ITS engine, nothing restarts
/// it, and live location receive is dead until the app is relaunched.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/background_location_task.dart';

void main() {
  const backoff = Duration(minutes: 15);

  SessionReclaimDecision decide({
    bool hasDataDir = true,
    bool hasIdentity = true,
    bool wipePending = false,
    bool guardHeld = true,
    int? lastAttemptMs,
    int nowMs = 1000000000,
  }) => evaluateSessionReclaimGates(
    hasDataDir: hasDataDir,
    hasIdentity: hasIdentity,
    wipePending: wipePending,
    guardHeld: guardHeld,
    lastAttemptMs: lastAttemptMs,
    nowMs: nowMs,
    backoff: backoff,
  );

  test('all preconditions satisfied authorises the probe', () {
    expect(decide(), SessionReclaimDecision.proceed);
  });

  group('each gate declines on its own', () {
    test('no data directory', () {
      expect(decide(hasDataDir: false), SessionReclaimDecision.noDataDir);
    });

    test('no identity — there is no session to open', () {
      expect(decide(hasIdentity: false), SessionReclaimDecision.noIdentity);
    });

    test('a pending MLS wipe outranks everything', () {
      // Re-opening the database would recreate state that is supposed to be
      // destroyed. This must win even when every other input says "go".
      expect(decide(wipePending: true), SessionReclaimDecision.wipePending);
    });

    test('guard not held — the failure was something a reclaim cannot fix', () {
      // A locked keyring or a full disk also fails the open. Reclaiming then
      // tears down the engine for a cause it has no bearing on.
      expect(decide(guardHeld: false), SessionReclaimDecision.guardNotHeld);
    });
  });

  group('gate precedence', () {
    test('the wipe marker outranks the guard check and the backoff', () {
      expect(
        decide(wipePending: true, guardHeld: false, lastAttemptMs: 999999999),
        SessionReclaimDecision.wipePending,
      );
    });

    test('a missing identity outranks a held guard', () {
      expect(
        decide(hasIdentity: false, guardHeld: true),
        SessionReclaimDecision.noIdentity,
      );
    });
  });

  group('the rate limit', () {
    // The reviewer-identified blind spot: a source scan sees the KEY but not
    // the operator, so flipping `<` to `>` would invert the limit invisibly.
    test('a fresh attempt declines', () {
      expect(
        decide(nowMs: 1000000, lastAttemptMs: 1000000),
        SessionReclaimDecision.backoffActive,
      );
    });

    test('just inside the window declines', () {
      expect(
        decide(
          nowMs: 1000000 + backoff.inMilliseconds - 1,
          lastAttemptMs: 1000000,
        ),
        SessionReclaimDecision.backoffActive,
      );
    });

    test('exactly at the window proceeds', () {
      expect(
        decide(nowMs: 1000000 + backoff.inMilliseconds, lastAttemptMs: 1000000),
        SessionReclaimDecision.proceed,
      );
    });

    test('past the window proceeds', () {
      expect(
        decide(
          nowMs: 1000000 + backoff.inMilliseconds * 4,
          lastAttemptMs: 1000000,
        ),
        SessionReclaimDecision.proceed,
      );
    });

    test('a never-attempted marker proceeds', () {
      expect(decide(lastAttemptMs: null), SessionReclaimDecision.proceed);
    });

    test('a clock that jumped BACKWARD stays restrictive', () {
      // `nowMs - lastAttemptMs` goes negative, which is still `< backoff`, so
      // the limit holds. The failure direction here matters: becoming
      // permissive on a clock change would let a device with bad time reclaim
      // on every tick.
      expect(
        decide(nowMs: 500, lastAttemptMs: 1000000),
        SessionReclaimDecision.backoffActive,
      );
    });
  });

  group('the decision is a function of its inputs only', () {
    test('repeated calls with identical inputs agree', () {
      // Guards against someone reintroducing hidden state (a static counter, a
      // clock read) into what must stay pure to be testable.
      final first = decide(lastAttemptMs: 999);
      final second = decide(lastAttemptMs: 999);
      expect(first, second);
    });

    test('every enum value is reachable except by construction', () {
      // If a new variant is added without a path to it, that is a gate wired
      // nowhere — the failure mode this catches.
      final reached = <SessionReclaimDecision>{
        decide(),
        decide(hasDataDir: false),
        decide(hasIdentity: false),
        decide(wipePending: true),
        decide(guardHeld: false),
        decide(lastAttemptMs: 1000000, nowMs: 1000000),
      };
      expect(
        reached,
        containsAll(SessionReclaimDecision.values),
        reason: 'every SessionReclaimDecision must be produced by some input '
            'combination, or a gate exists that nothing can trigger',
      );
    });
  });
}
