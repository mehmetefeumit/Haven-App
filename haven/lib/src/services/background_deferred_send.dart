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
import 'package:haven/src/services/circle_service.dart'
    show Circle, DecryptedLocation;
import 'package:haven/src/services/location_auto_commit.dart'
    show resolveRunawayCap;
import 'package:haven/src/services/nostr_circle_service.dart'
    show peerLocationFromFfi;
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/utils/event_tags.dart';
import 'package:haven/src/utils/log_alias.dart';

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
///
/// Returns the peer locations those resolutions REPLAYED: resolving a commit
/// makes the engine replay everything it buffered while that commit was in
/// flight. The rows are already persisted Rust-side; the caller feeds them to
/// this isolate's own `LocationSharingService` for the cache and the
/// receive-liveness stamp — and to NO provider, because this runs in the
/// foreground service's isolate. A replay that stages the NEXT eviction comes
/// back on the same outcome and is run through this same ladder until the
/// worklist is empty, with [resolveRunawayCap] as the runaway guard.
Future<List<ReplayedFix>> publishStagedCommits({
  required NostrRelayService relayService,
  required CircleManagerFfi circleManager,
  required Circle circle,
  required DeferredSendFfi deferred,
}) async {
  final locations = <ReplayedFix>[];
  final proposals = <String>[];
  // A ref resolved once is never resolved again: the second call would be
  // against a token the engine has already retired.
  final resolvedTokens = <BigInt>{};
  var worklist = deferred.commits;

  for (var generation = 0; worklist.isNotEmpty; generation++) {
    if (generation == resolveRunawayCap) {
      // Rule 15: never add a circle handle here — "circle#a91f3c ran a
      // cascade" says a peer just left that circle.
      debugPrint(
        '[BackgroundTask] deferred commit ladder stopped at the runaway cap; '
        '${magnitudeBucket(worklist.length)} commit(s) stand owed',
      );
      // Reported, not abandoned — the same rung `resolveAutoCommits` takes,
      // and the right one for an isolate that dies at the end of this cycle:
      // the report drains that resolution's replay (peer fixes that exist
      // nowhere else) and leaves the removal owed exactly as walking away
      // would.
      for (final commit in worklist) {
        try {
          final resolved = await circleManager.publishFailed(
            pending: commit.pending,
          );
          locations.addAll(_fixesOf(resolved));
          proposals.addAll(resolved.proposals);
        } on Object catch (e) {
          debugPrint(
            '[BackgroundTask] deferred commit fail-report failed: '
            '${e.runtimeType}',
          );
        }
      }
      break;
    }
    final next = <CommitToPublishFfi>[];
    for (final commit in worklist) {
      if (!resolvedTokens.add(commit.pending.token)) continue;
      final target = await _relaysForCommit(
        circleManager: circleManager,
        commitEventJson: commit.commitEventJson,
        ambient: circle,
      );
      var published = false;
      if (target.isNotEmpty) {
        try {
          final result = await relayService.publishEvent(
            eventJson: commit.commitEventJson,
            relays: target,
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
        final DecryptLocationOutcomeFfi resolved;
        if (published) {
          resolved = await circleManager.confirmPublished(
            pending: commit.pending,
          );
        } else {
          // Leaves the eviction owed rather than discarding it — see this
          // function's doc for why Rust refuses the rollback.
          resolved = await circleManager.publishFailed(
            pending: commit.pending,
          );
        }
        locations.addAll(_fixesOf(resolved));
        proposals.addAll(resolved.proposals);
        next.addAll(resolved.autoCommits);
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] deferred commit '
          '${published ? "confirm" : "fail-report"} failed: ${e.runtimeType}',
        );
      }
    }
    worklist = next;
  }

  // A proposal a resolution replayed is published on the same terms as the
  // deferral's own (no confirm, failures swallowed) — inline rather than
  // through `publishDeferredProposals`, which takes the deferral it came with
  // — but to the relays of the circle its OWN `h` tag names, never this
  // cycle's. The wrong relay set tells those operators about a second group
  // and may never reach the members the leave is addressed to.
  if (proposals.isNotEmpty) {
    final held = await _heldCircles(circleManager);
    for (final eventJson in proposals) {
      final h = hTagOf(eventJson);
      final target = held
          .where((c) => _hexOf(c.circle.nostrGroupId) == h)
          .firstOrNull;
      if (target == null || target.circle.relays.isEmpty) {
        debugPrint(
          '[BackgroundTask] replayed proposal names a circle this device '
          'does not hold — not published',
        );
        continue;
      }
      try {
        final result = await relayService.publishEvent(
          eventJson: eventJson,
          relays: target.circle.relays,
        );
        if (result.acceptedBy.isEmpty) {
          debugPrint(
            '[BackgroundTask] replayed proposal rejected by all relays',
          );
        }
      } on Object catch (e) {
        debugPrint(
          '[BackgroundTask] replayed proposal publish failed: ${e.runtimeType}',
        );
      }
    }
  }

  return locations;
}

/// One peer fix a resolution replayed, with the group it belongs to.
///
/// The group id travels with the fix because a resolution's batch is NOT one
/// circle's — the engine's buffers are global — and the caller has to file
/// each one under the circle its own result names.
typedef ReplayedFix = ({List<int> mlsGroupId, DecryptedLocation decrypted});

/// The peer fixes in one resolved outcome, each keyed by its own group id.
Iterable<ReplayedFix> _fixesOf(DecryptLocationOutcomeFfi resolved) sync* {
  for (final result in resolved.results) {
    final decrypted = peerLocationFromFfi(result);
    if (decrypted == null) continue;
    yield (mlsGroupId: result.mlsGroupId.toList(), decrypted: decrypted);
  }
}

/// The circles this device holds, or an empty list when the read fails —
/// which routes every replayed proposal to its fail-closed rung.
Future<List<CircleWithMembersFfi>> _heldCircles(
  CircleManagerFfi circleManager,
) async {
  try {
    return await circleManager.getVisibleCircles();
  } on Object catch (e) {
    debugPrint(
      '[BackgroundTask] replayed proposal routing failed: ${e.runtimeType}',
    );
    return const [];
  }
}

/// Lowercase hex of a raw id, for matching an `h` tag against a circle.
String _hexOf(List<int> id) =>
    id.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The relays one staged commit must be published to: the circle its own `h`
/// tag names — the FFI-shape mirror of `location_auto_commit.dart`'s
/// `_relaysForCommit`.
///
/// [ambient] (this deferral's own circle) is the answer for the common case —
/// an `h` naming that same circle, which is every generation-0 commit, since
/// the ingest that staged it was this circle's. A commit a
/// RESOLUTION surfaced can belong to another group, because the engine's
/// buffers are global; publishing it to [ambient]'s relays would tell those
/// operators about the second group and might never reach the members it
/// evicts. An `h` naming no circle this device holds — or no `h` at all,
/// which a production kind-445 commit never omits — yields NO relays, which
/// takes the fail-report rung: the commit stays owed rather than being
/// published to the wrong place.
Future<List<String>> _relaysForCommit({
  required CircleManagerFfi circleManager,
  required String commitEventJson,
  required Circle ambient,
}) async {
  final h = hTagOf(commitEventJson);
  if (h == null) return const [];
  if (_hexOf(ambient.nostrGroupId) == h) return ambient.relays;
  final held = await _heldCircles(circleManager);
  final target = held
      .where((c) => _hexOf(c.circle.nostrGroupId) == h)
      .firstOrNull;
  if (target == null) {
    debugPrint(
      '[BackgroundTask] deferred commit names a circle this device does '
      'not hold — leaving it owed',
    );
    return const [];
  }
  return target.circle.relays;
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
