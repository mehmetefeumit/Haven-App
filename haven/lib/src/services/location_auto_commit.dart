/// The foreground poll planes' RECEIVE-SIDE auto-commit resolver: the peer
/// `SelfRemove` evictions a remaining member's MLS engine stages during ingest.
///
/// Split out of `location_sharing_service.dart` for one reason: everything here
/// resolves a `PendingCommitToken`, so it takes the 3-attempt
/// [RelayService.publishEvent] ladder and is never eligible for the one-shot
/// [RelayService.publishLocationEvent] the location plane takes. A location
/// nobody acked is superseded by the next tick; a commit is not — one that is
/// neither confirmed nor rolled back forks the group (Security Rule 13).
/// Keeping the two planes in separate files is what makes "no caller carrying a
/// pending token can reach the one-shot publish" a checkable property rather
/// than a reviewable one (`haven-core/tests/security_rule_gates.rs`). This is
/// the foreground mirror of `background_deferred_send.dart`, which did the same
/// for the foreground service.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/utils/event_tags.dart';
import 'package:haven/src/utils/log_alias.dart';

/// Runaway guard on the resolve ladder, mirroring Rust's
/// `haven_core::relay::auto_commit::RESOLVE_RUNAWAY_CAP` one-for-one.
///
/// NOT the normal exit: the ladder runs until its worklist is empty, because a
/// commit surfaced by a confirm has exactly the same Rule-13 obligation as the
/// one that surfaced it, and nothing else in a poll-only build ever redeems it
/// (`redeem_removal_deferrals` has one production driver, and it is the
/// live-sync session). Reaching this cap means a bug, and the disposition is
/// the fail-report rung below — never a silent discard.
///
/// It counts commits resolved per CALL, and 16 is safe only because that
/// breadth is bounded elsewhere: an account holds at most
/// `kMaxCirclesPerAccount` (10, `publish_stagger.dart`) circles, so a batch in
/// which every circle loses a member still stays under this — raise that
/// bound past this one and an ordinary mass-leave reaches the cap, where in a
/// short-lived isolate the unresolved work is terminal.
const int resolveRunawayCap = 16;

/// Nothing replayed — the shape every rung that resolved no batch returns.
const DecryptLocationOutcome emptyDecryptOutcome = DecryptLocationOutcome(
  results: [],
  autoCommits: [],
  proposals: [],
);

/// Publishes every [autoCommits] entry and resolves its staged state.
///
/// `decryptLocationCollectingCommits` surfaces a peer `SelfRemove` eviction the
/// engine auto-staged during ingest, instead of the engine rolling it back —
/// because the FOREGROUND POLL paths own a relay handle and the Rust
/// `CircleManagerFfi` does not. Live-sync and background catch-up already
/// publish these in-Rust via
/// `haven_core::relay::auto_commit::resolve_receive_publish_work` and never
/// surface an auto-commit to Dart; this is the Dart mirror of that exact
/// function for the one receive plane it cannot reach.
///
/// ONE publish attempt per entry (no retry/backoff, matching the Rust reference
/// one-for-one): confirm on a ≥1-relay OK-ack, else report the failure — NEVER
/// confirm before an ack, NEVER drop an entry silently (either would re-fork or
/// re-open the group the leaver departed).
///
/// ## What an unacked commit is NOT
///
/// It is not re-surfaced by a later tick. This doc used to claim the buffered
/// `SelfRemove` proposal made the poll cadence its own retry; a probe against
/// the engine at the pinned MDK rev disproved that — the in-memory auto-commit
/// schedule is dropped before staging, `do_publish_failed` does not re-arm it,
/// and a redelivered proposal short-circuits to `Buffered` off its durable
/// `Created` row. Nothing re-derives the eviction.
///
/// What keeps it instead is a durable obligation Rust recorded BEFORE the
/// commit crossed the FFI (`CircleManager::owe_removal_publish`). So
/// [CircleService.failPendingCommit] does not roll a commit like this back at
/// all: it leaves it staged and OWED, and the next FOREGROUND live-sync open
/// publishes it. That is also what makes a process killed mid-publish visible —
/// the row outlives it and the next foreground open reports the circle.
///
/// [circle] is the caller's snapshot; the CURRENT relays are re-read from
/// [circleService] first (mirrors `removeMember` / `updateCircleRelays`, which
/// re-read `circle.relays` rather than trust a possibly-stale caller-held
/// snapshot — a relay rotation could have landed between a poll cycle's
/// hydration and this decrypt). A `null` [circle] is the deferred-send case
/// where the circle lookup itself failed: there are no relays to publish to, so
/// the entry takes the same failure rung, which leaves the removal owed rather
/// than discarding it.
///
/// Best-effort per entry: a failure is logged, never thrown, so one bad
/// auto-commit cannot abort the surrounding decrypt/persist loop.
///
/// ## Why this is a LOOP
///
/// Resolving a commit makes the engine replay everything it buffered while that
/// commit was in flight, and that replay can stage the NEXT eviction — a second
/// leaver whose `SelfRemove` was buffered behind the first. Those come back on
/// the resolution's own outcome, carry the same Rule-13 obligation, and are
/// re-fed here until the worklist is empty. Returns everything the replays
/// folded: peer locations for the caller to surface, and proposals to publish.
Future<DecryptLocationOutcome> resolveAutoCommits({
  required RelayService relayService,
  required CircleService circleService,
  required List<PendingAutoCommit> autoCommits,
  required Circle? circle,
}) async {
  if (autoCommits.isEmpty) return emptyDecryptOutcome;

  var relays = circle?.relays ?? const <String>[];
  if (circle != null) {
    try {
      final fresh = await circleService.getCircle(circle.mlsGroupId);
      if (fresh != null && fresh.relays.isNotEmpty) {
        relays = fresh.relays;
      }
    } on Object catch (e) {
      debugPrint(
        '[LocationService] auto-commit relay lookup failed: ${e.runtimeType}',
      );
    }
  }

  if (relays.isEmpty) {
    debugPrint(
      '[LocationService] auto-commit: no relays available — leaving it owed',
    );
  }

  final results = <LocationEventResult>[];
  final proposals = <String>[];
  // A ref resolved once is never resolved again: the second call would be
  // against a token the engine has already retired.
  final resolvedTokens = <BigInt>{};
  var worklist = autoCommits;

  for (var generation = 0; worklist.isNotEmpty; generation++) {
    if (generation == resolveRunawayCap) {
      // Rule 15: never add a circle handle here. "circle#a91f3c ran a
      // cascade" is a per-circle activity signal — that a peer just left it.
      debugPrint(
        '[LocationService] auto-commit ladder stopped at the runaway cap; '
        '${magnitudeBucket(worklist.length)} commit(s) stand owed',
      );
      for (final commit in worklist) {
        final outcome = await _reportUnacked(circleService, commit);
        results.addAll(outcome.results);
        proposals.addAll(outcome.proposals);
      }
      break;
    }

    final next = <PendingAutoCommit>[];
    for (final commit in worklist) {
      if (!resolvedTokens.add(commit.pendingToken.value)) continue;
      final target = await _relaysForCommit(
        circleService: circleService,
        commitEventJson: commit.commitEventJson,
        ambient: circle,
        ambientRelays: relays,
      );
      final outcome = target.isEmpty
          ? await _reportUnacked(circleService, commit)
          : await _publishAndConfirmAutoCommit(
              relayService: relayService,
              circleService: circleService,
              commit: commit,
              relays: target,
            );
      results.addAll(outcome.results);
      proposals.addAll(outcome.proposals);
      next.addAll(outcome.autoCommits);
    }
    worklist = next;
  }

  return DecryptLocationOutcome(
    results: results,
    autoCommits: const [],
    proposals: proposals,
  );
}

/// The relays one staged commit must be published to: the circle its own `h`
/// tag names.
///
/// [ambientRelays] (the caller's circle, freshly re-read) is the answer for the
/// common case — an `h` naming that same circle, which is every
/// first-generation commit, since the ingest that staged it was that circle's.
/// A commit a RESOLUTION surfaced can belong to another group, because the
/// engine's buffers are global; sending it to the ambient relay set would tell
/// those operators about the second group and might never reach the members it
/// evicts. A missing `h` — a production kind-445 commit never omits one — or
/// one naming no circle this device holds yields NO relays, which takes the
/// fail-report rung — the commit stays owed rather than being published to
/// the wrong place, or to the ambient circle on a guess.
Future<List<String>> _relaysForCommit({
  required CircleService circleService,
  required String commitEventJson,
  required Circle? ambient,
  required List<String> ambientRelays,
}) async {
  final h = hTagOf(commitEventJson);
  if (h == null) {
    debugPrint(
      '[LocationService] auto-commit carries no `h` tag — leaving it owed',
    );
    return const [];
  }
  if (ambient != null && _hexOf(ambient.nostrGroupId) == h) {
    return ambientRelays;
  }
  try {
    final held = await circleService.getVisibleCircles();
    final target = held
        .where((c) => _hexOf(c.nostrGroupId) == h)
        .firstOrNull;
    if (target != null) return target.relays;
  } on Object catch (e) {
    debugPrint(
      '[LocationService] auto-commit routing lookup failed: ${e.runtimeType}',
    );
  }
  debugPrint(
    '[LocationService] auto-commit names a circle this device does not hold '
    '— leaving it owed',
  );
  return const [];
}

/// Lowercase hex of a raw id, for matching an `h` tag against a circle.
String _hexOf(List<int> id) =>
    id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Reports "no relay acked" for one commit, returning whatever that resolution
/// replayed.
///
/// NOT a rollback: Rust refuses to discard a removal-bearing commit, so this
/// leaves the removal owed for the next foreground redemption. Discarding it
/// would evict nobody and still wedge the circle — see this library's doc.
Future<DecryptLocationOutcome> _reportUnacked(
  CircleService circleService,
  PendingAutoCommit commit,
) async {
  try {
    return await circleService.failPendingCommit(commit.pendingToken);
  } on Object catch (e) {
    debugPrint(
      '[LocationService] auto-commit fail-report failed: ${e.runtimeType}',
    );
    return emptyDecryptOutcome;
  }
}

/// Publishes one [PendingAutoCommit]'s event to [relays] — ONE attempt,
/// mirroring `haven_core::relay::auto_commit::resolve_receive_publish_work`
/// one-for-one. Confirms on a ≥1-relay OK-ack; otherwise reports the failure,
/// which for a removal-bearing commit leaves it OWED rather than rolling it
/// back (see this library's doc for the retry that actually exists). Never
/// throws.
///
/// Returns what the resolution replayed, so the caller can surface the peer
/// locations that were buffered behind this commit and run the next generation.
Future<DecryptLocationOutcome> _publishAndConfirmAutoCommit({
  required RelayService relayService,
  required CircleService circleService,
  required PendingAutoCommit commit,
  required List<String> relays,
}) async {
  var published = false;
  try {
    final result = await relayService.publishEvent(
      eventJson: commit.commitEventJson,
      relays: relays,
    );
    published = result.acceptedBy.isNotEmpty;
    if (!published) {
      debugPrint(
        '[LocationService] auto-commit publish rejected by all relays',
      );
    }
  } on Object catch (e) {
    debugPrint(
      '[LocationService] auto-commit publish failed: ${e.runtimeType}',
    );
  }

  try {
    if (published) {
      return await circleService.confirmPendingCommit(commit.pendingToken);
    }
    // The removal stays owed — Rust will not discard a peer's eviction, and
    // the obligation it recorded before this commit crossed the FFI is what
    // the next foreground live-sync open publishes.
    return await circleService.failPendingCommit(commit.pendingToken);
  } on Object catch (e) {
    debugPrint(
      '[LocationService] auto-commit '
      '${published ? "confirm" : "fail-report"} failed: ${e.runtimeType}',
    );
    return emptyDecryptOutcome;
  }
}
