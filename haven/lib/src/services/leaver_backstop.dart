/// Default bound on leaver-backstop SelfRemove re-issues (REV-1, driver 2).
///
/// Convergence of a departing member's leave has two drivers: any member not in
/// an open settle window auto-commits the SelfRemove (driver 1, no code), and —
/// for the vanishingly-rare case where EVERY member is windowed at once — the
/// leaver itself re-issues a fresh SelfRemove until it observes its own removal
/// (driver 2, this loop). The budget bounds the re-issue tail so the leaver's
/// key-material wipe is never delayed indefinitely; the residual (crash + all-
/// windowed + never-returns) is disclosed in `haven-core/SECURITY.md`.
const int kDefaultLeaverReissueBudget = 3;

/// Runs the REV-1 leaver backstop after an initial `propose_leave` SelfRemove
/// has been published.
///
/// The loop, once per iteration (up to [maxReissues]):
/// 1. polls [stillAMember] — the leaver's own removal-liveness predicate;
/// 2. if the eviction has landed (`false`) → runs [completeLeave] (the wipe)
///    and returns immediately, re-issuing nothing;
/// 3. otherwise re-issues a FRESH `propose_leave` via [reissue];
/// 4. waits [waitBetween] before the next poll.
///
/// On budget exhaustion (the leaver was never removed within the budget) the
/// loop still runs [completeLeave] — it never spins unbounded and never delays
/// the wipe indefinitely. This is the disclosed bounded residual.
///
/// The loop touches NO secret material. `propose_leave` publishes under an
/// ephemeral per-message key and consumes no identity secret, so [reissue]
/// takes none — there is nothing to materialise or scrub (Rule 9). A concurrent
/// logout mid-backstop is the CALLER's responsibility: its injected
/// [stillAMember], [reissue], and [completeLeave] each throw (via the service's
/// synchronous wipe latch) before any MLS write once logout latches, and this
/// loop propagates that throw — so the caller's durable leave marker persists
/// for a launch-resume retry rather than a write landing against a wiped
/// identity.
///
/// Every operation is injected, so the loop is unit-testable without the FFI
/// bridge, the `liveSyncEnabled` flag, or a real MLS group.
Future<void> runLeaverBackstop({
  required Future<bool> Function() stillAMember,
  required Future<void> Function() reissue,
  required Future<void> Function() completeLeave,
  required Future<void> Function(int attempt) waitBetween,
  int maxReissues = kDefaultLeaverReissueBudget,
}) async {
  for (var attempt = 0; attempt < maxReissues; attempt++) {
    // Has the eviction landed yet? `stillAMember` fails SAFE to false at the
    // FFI boundary (group gone / self-evicted), so a removed leaver stops here.
    if (!await stillAMember()) {
      await completeLeave();
      return;
    }

    // Still a member → re-issue a fresh SelfRemove. No secret is touched: the
    // re-issue publishes under an ephemeral key. A concurrent-logout wipe makes
    // this fail closed (throws, which propagates out of the loop) instead of
    // writing MLS state against a wiped identity.
    await reissue();

    await waitBetween(attempt);
  }

  // Budget exhausted: wipe anyway (the disclosed residual — never spin, never
  // delay the wipe indefinitely).
  await completeLeave();
}
