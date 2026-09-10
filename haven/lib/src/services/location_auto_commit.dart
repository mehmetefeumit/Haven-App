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
Future<void> resolveAutoCommits({
  required RelayService relayService,
  required CircleService circleService,
  required List<PendingAutoCommit> autoCommits,
  required Circle? circle,
}) async {
  if (autoCommits.isEmpty) return;

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

  for (final commit in autoCommits) {
    if (relays.isEmpty) {
      debugPrint(
        '[LocationService] auto-commit: no relays available — leaving it owed',
      );
      try {
        // NOT a rollback: Rust refuses to discard a removal-bearing commit, so
        // this reports "no relay acked" and the removal stays owed for the next
        // foreground redemption. Discarding it would evict nobody and still
        // wedge the circle — see this library's doc.
        await circleService.failPendingCommit(commit.pendingToken);
      } on Object catch (e) {
        debugPrint(
          '[LocationService] auto-commit fail-report failed: '
          '${e.runtimeType}',
        );
      }
      continue;
    }
    await _publishAndConfirmAutoCommit(
      relayService: relayService,
      circleService: circleService,
      commit: commit,
      relays: relays,
    );
  }
}

/// Publishes one [PendingAutoCommit]'s event to [relays] — ONE attempt,
/// mirroring `haven_core::relay::auto_commit::resolve_receive_publish_work`
/// one-for-one. Confirms on a ≥1-relay OK-ack; otherwise reports the failure,
/// which for a removal-bearing commit leaves it OWED rather than rolling it
/// back (see this library's doc for the retry that actually exists). Never
/// throws.
Future<void> _publishAndConfirmAutoCommit({
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
      await circleService.confirmPendingCommit(commit.pendingToken);
    } else {
      // The removal stays owed — Rust will not discard a peer's eviction, and
      // the obligation it recorded before this commit crossed the FFI is what
      // the next foreground live-sync open publishes.
      await circleService.failPendingCommit(commit.pendingToken);
    }
  } on Object catch (e) {
    debugPrint(
      '[LocationService] auto-commit '
      '${published ? "confirm" : "fail-report"} failed: ${e.runtimeType}',
    );
  }
}
