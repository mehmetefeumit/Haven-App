/// The foreground service's DEFERRED-send plane: the staged commits and bare
/// proposals the MLS engine hands back instead of an encrypted location.
///
/// Split out of `background_location_task.dart` for one reason: everything
/// here resolves a `PendingStateRefFfi`, so it takes the 3-attempt
/// [NostrRelayService.publishEvent] ladder and is never eligible for the
/// one-shot [NostrRelayService.publishLocationEvent] the location plane
/// takes. A location nobody acked is superseded by the next tick; a commit is
/// not — one that is neither confirmed nor rolled back forks the group
/// (Security Rule 13). Keeping the two planes in separate files is what makes
/// "no caller carrying a pending ref can reach the one-shot publish" a
/// checkable property rather than a reviewable one
/// (`haven-core/tests/security_rule_gates.rs`).
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/nostr_relay_service.dart';

/// Runs the Rule-13 ladder over the commits a DEFERRED send handed back.
///
/// `should_queue_outbound_intent` returns true precisely when the engine has
/// just STAGED a peer's `SelfRemove` eviction, and that commit arrives on the
/// deferred outcome carrying a pending token. All three of the obvious
/// dispositions are wrong: confirming applies a commit no relay acked;
/// rolling it back drops the engine's retry schedule so the leaver never
/// leaves; dropping it pins the group in `PendingPublish`, where every later
/// send fails. Publish, then confirm on a ≥1-relay ACK, else report the
/// failure.
///
/// That failure report is NOT a rollback. Rust recorded the publish as OWED
/// before the commit crossed the FFI (`CircleManager::owe_removal_publish`)
/// and refuses to discard a peer's eviction, so the commit stays staged and
/// the next FOREGROUND live-sync open publishes it. Nothing else would: a
/// probe against the engine at the pinned MDK rev showed the eviction is never
/// re-derived once discarded.
///
/// Never throws — a failure here must not abort the publish loop. The caller
/// registers the returned future as commit-critical work, because abandoning
/// it between `publishEvent` and `confirmPublished` leaves a commit that is
/// neither confirmed nor reported while possibly already on a relay.
Future<void> publishStagedCommits({
  required NostrRelayService relayService,
  required CircleManagerFfi circleManager,
  required Circle circle,
  required DeferredSendFfi deferred,
}) async {
  for (final commit in deferred.commits) {
    var published = false;
    if (circle.relays.isNotEmpty) {
      try {
        final result = await relayService.publishEvent(
          eventJson: commit.commitEventJson,
          relays: circle.relays,
        );
        published = result.acceptedBy.isNotEmpty;
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] deferred commit publish failed: '
          '${e.runtimeType}',
        );
      }
    }
    try {
      if (published) {
        await circleManager.confirmPublished(pending: commit.pending);
      } else {
        // Leaves the eviction owed rather than discarding it — see this
        // function's doc for why Rust refuses the rollback.
        await circleManager.publishFailed(pending: commit.pending);
      }
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] deferred commit '
        '${published ? "confirm" : "fail-report"} failed: ${e.runtimeType}',
      );
    }
  }
}

/// Publishes the bare proposals a DEFERRED send handed back, to the circle's
/// relays.
///
/// Mirrors the foreground's `LocationSharingService._publishDeferredProposals`.
/// No confirm step and no rollback: a proposal carries no staged state, so
/// there is nothing to apply. Losing one costs a cycle rather than
/// correctness — the durable leave request that produced it makes a later
/// convergence pass re-emit it — so every failure is logged and swallowed
/// rather than allowed to abort the publish loop.
Future<void> publishDeferredProposals({
  required NostrRelayService relayService,
  required Circle circle,
  required DeferredSendFfi deferred,
}) async {
  if (deferred.proposals.isEmpty || circle.relays.isEmpty) return;
  for (final eventJson in deferred.proposals) {
    try {
      final result = await relayService.publishEvent(
        eventJson: eventJson,
        relays: circle.relays,
      );
      if (result.acceptedBy.isEmpty) {
        debugPrint('[BackgroundTask] deferred proposal rejected by all relays');
      }
    } on Object catch (e) {
      debugPrint(
        '[BackgroundTask] deferred proposal publish failed: ${e.runtimeType}',
      );
    }
  }
}
