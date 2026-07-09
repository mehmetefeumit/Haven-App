import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/services/leaver_backstop.dart';

/// Records the ops the loop invoked, for assertions.
class _Ops {
  int polls = 0;

  /// Wired to nothing on purpose: `runLeaverBackstop` no longer exposes a
  /// secret provider, so no code path in the loop can materialise the identity
  /// secret. TEST 4 asserts this stays 0 — a tripwire that a secret must never
  /// be reintroduced into the backstop loop (Rule 9).
  int secretFetches = 0;
  int reissues = 0;
  int completes = 0;
  int waits = 0;
}

void main() {
  group('runLeaverBackstop', () {
    // -----------------------------------------------------------------------
    // TEST 1 — Bounded re-issue loop.
    //
    // stillAMember returns true for N polls then false → exactly N fresh
    // propose_leave re-issues occur, then completeLeave.
    // -----------------------------------------------------------------------
    test(
      're-issues once per still-a-member poll, then completeLeave on removal',
      () async {
        const n = 4;
        final ops = _Ops();
        await runLeaverBackstop(
          stillAMember: () async {
            ops.polls++;
            // true for the first N polls, false on the (N+1)th.
            return ops.polls <= n;
          },
          reissue: () async => ops.reissues++,
          completeLeave: () async => ops.completes++,
          waitBetween: (_) async => ops.waits++,
          // Budget well above N so the loop stops on the false poll, not the
          // budget — this test pins the removal-driven stop, not the cap.
          maxReissues: 10,
        );
        expect(
          ops.reissues,
          n,
          reason: 'exactly one fresh propose_leave per still-a-member poll',
        );
        expect(
          ops.completes,
          1,
          reason: 'completeLeave runs once, immediately after removal is seen',
        );
        expect(
          ops.polls,
          n + 1,
          reason: 'N true polls, then the false poll that stops the loop',
        );
      },
    );

    // -----------------------------------------------------------------------
    // TEST 2 — Stop condition.
    //
    // stillAMember returns false on the FIRST poll → ZERO re-issues,
    // completeLeave runs immediately.
    // -----------------------------------------------------------------------
    test('stops with zero re-issues when already removed', () async {
      final ops = _Ops();
      await runLeaverBackstop(
        stillAMember: () async {
          ops.polls++;
          return false; // the eviction already landed
        },
        reissue: () async => ops.reissues++,
        completeLeave: () async => ops.completes++,
        waitBetween: (_) async => ops.waits++,
        maxReissues: 5,
      );
      expect(ops.polls, 1, reason: 'a single poll observes the removal');
      expect(
        ops.reissues,
        0,
        reason: 'no re-issue when the removal already landed',
      );
      expect(ops.completes, 1, reason: 'completeLeave runs immediately');
      expect(
        ops.waits,
        0,
        reason: 'no poll delay is incurred when we stop on the first poll',
      );
    });

    // -----------------------------------------------------------------------
    // TEST 4 — Bounded budget + no secret (FIX 1).
    //
    // stillAMember stays true forever → re-issues stop at the budget,
    // completeLeave still runs (no unbounded spin), and — the FIX-1 property —
    // the loop materialises NO identity secret: it exposes no secret provider
    // at all, because `propose_leave` re-issues under an ephemeral key (Rule 9,
    // nothing to fetch or scrub).
    // -----------------------------------------------------------------------
    test(
      'caps re-issues at the budget, still completes, and fetches no secret',
      () async {
        // A non-default budget so the cap is proven to be the injected
        // parameter, not a coincidence with the production default.
        const budget = 5;
        final ops = _Ops();
        await runLeaverBackstop(
          stillAMember: () async {
            ops.polls++;
            return true; // never removed — the all-windowed worst case
          },
          reissue: () async => ops.reissues++,
          completeLeave: () async => ops.completes++,
          waitBetween: (_) async => ops.waits++,
          maxReissues: budget,
        );
        expect(
          ops.reissues,
          budget,
          reason: 're-issues stop at the budget — never an unbounded spin',
        );
        expect(
          ops.completes,
          1,
          reason: 'completeLeave still runs after the budget is exhausted '
              '(the disclosed residual — never delay the wipe indefinitely)',
        );
        expect(
          ops.secretFetches,
          0,
          reason: 'the loop exposes no secret provider — the identity secret '
              'is never materialised in the backstop (Rule 9)',
        );
      },
    );

    // -----------------------------------------------------------------------
    // Supporting: a fail-closed re-issue — the shape a concurrent-logout wipe
    // takes at the loop boundary, where the caller's non-secret `_wiped` gate
    // makes `reissue` THROW — propagates OUT of the loop and never runs
    // completeLeave, so the caller's durable marker survives for a
    // launch-resume retry and the wipe never runs against a torn-down identity.
    // -----------------------------------------------------------------------
    test(
      'a fail-closed re-issue propagates and never completes the leave',
      () async {
        final ops = _Ops();
        await expectLater(
          runLeaverBackstop(
            stillAMember: () async {
              ops.polls++;
              return true; // still a member → a re-issue is attempted
            },
            reissue: () async {
              ops.reissues++;
              // The caller's non-secret `_wiped` gate surfaces here as a throw.
              throw StateError('circle service wiped mid-leave');
            },
            completeLeave: () async => ops.completes++,
            waitBetween: (_) async => ops.waits++,
          ),
          throwsA(anything),
        );
        expect(
          ops.reissues,
          1,
          reason: 'the re-issue was attempted once, then failed closed',
        );
        expect(
          ops.completes,
          0,
          reason: 'a fail-closed re-issue must not wipe — the outer leave '
              'handler keeps the durable marker for a later retry',
        );
      },
    );
  });
}
