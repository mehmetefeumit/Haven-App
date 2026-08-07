/// Per-circle publish-due bookkeeping for the background isolate.
///
/// Decorrelation (privacy): the app must NOT publish a kind-445 location to
/// every circle on one shared tick — a relay that sees several distinct `#h`
/// (nostr_group_id) tags all receiving an event within the same instant, every
/// cycle, can correlate those otherwise-unlinkable pseudonymous circles as one
/// device. Worse, the engine binds the outer kind-445 `created_at` to the inner
/// app event's whole-second timestamp, so co-timed publishes carry a
/// byte-identical `created_at` INSIDE the signed event — readable from an
/// archive by someone who never saw the socket (see [PublishStagger]). The
/// foreground breaks this with one independent [JitteredScheduler] per circle;
/// the background isolate — which runs a single periodic `onRepeatEvent` cycle
/// — breaks it by tracking an INDEPENDENT next-due time per circle here and
/// publishing only the circles whose own time has come.
///
/// This class is necessary but NOT sufficient on its own: `onRepeatEvent` is a
/// coarse poll (`kBackgroundRepeatInterval`, 72 s), so two circles whose
/// independent due-times fall in the same 72 s bucket are still selected by the
/// same cycle. The caller must therefore ALSO pace the publishes it selects —
/// `dueKeysUpTo` returns them in due-time order for exactly that.
///
/// This is a pure, FFI-free value object so the decorrelation logic is unit
/// testable without the Rust bridge or a live foreground-service (the
/// surrounding [background task handler] is inherently bridge-bound and cannot
/// run under `flutter test`).
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/publish_stagger.dart';

/// Tracks, per circle key, the wall-clock time at which that circle is next
/// eligible to publish. Keys are opaque to this class; callers use the public
/// `nostr_group_id` hex (never the real MLS group id — CLAUDE.md Rule 4).
class PerCircleDueTracker {
  final Map<String, DateTime> _nextDueAt = {};

  /// Registers [key] with an initial due-time IF it is not already tracked.
  ///
  /// Idempotent: an already-tracked circle keeps its existing schedule (so a
  /// circle that has been publishing on its own cadence is never yanked back
  /// to a fresh phase just because it was seen again this cycle).
  ///
  /// The caller chooses [initialDue], and it must NOT be the same instant for
  /// every circle. Seeding the whole roster at one `now` is what re-created
  /// the shared-`created_at` burst on EVERY foreground→background handoff:
  /// [pruneToKeys] empties this map while the foreground owns publishing, so
  /// the seed runs again on every handoff, and a shared seed makes every
  /// circle due in the same instant. The background seeds the FIRST circle
  /// due-now and staggers the rest by [PublishStagger] gaps, which keeps the
  /// handoff's worst-case inter-publish gap inside one background cycle plus
  /// one stagger spread (see `LOCATION_MESSAGE_RETENTION_SECS`).
  void seedIfAbsent(String key, DateTime initialDue) {
    _nextDueAt.putIfAbsent(key, () => initialDue);
  }

  /// Whether [key] already has a schedule (so a seed would be a no-op).
  ///
  /// Lets a caller sample stagger offsets for the circles that actually need
  /// one, instead of burning offsets on circles already mid-cadence.
  bool isTracked(String key) => _nextDueAt.containsKey(key);

  /// Registers every UNTRACKED key in [keys] with an INDEPENDENT, CSPRNG
  /// staggered initial due-time: a random permutation puts one circle "due
  /// now" and pushes each later one a further [PublishStagger] gap out.
  ///
  /// This replaces a shared `seedIfAbsent(key, now)` over the whole roster,
  /// which was the background half of the shared-`created_at` leak. Because
  /// the background empties this map on every cycle where the foreground owns
  /// publishing ([pruneToKeys] with an empty set), the seed re-runs on EVERY
  /// foreground→background handoff — so a shared seed re-burst every single
  /// handoff, not just the first.
  ///
  /// Already-tracked circles are skipped entirely rather than merely being
  /// idempotent seeds: they keep their own phase AND they do not consume a
  /// stagger slot, so a long-running roster never pushes a genuinely new
  /// circle to the far end of the spread.
  ///
  /// Offsets stay within `stagger.maxSpreadFor(n)` of [from], well inside one
  /// `kBackgroundRepeatInterval`, so a staggered circle is serviced by the
  /// SAME cycle rather than slipping a whole polling interval — that is what
  /// keeps the handoff from widening a circle's worst-case inter-publish gap
  /// by 72 s instead of by the spread.
  void seedStaggered(
    Iterable<String> keys,
    DateTime from,
    PublishStagger stagger,
  ) {
    final fresh = stagger.shuffled(<String>[
      for (final key in keys)
        if (!isTracked(key)) key,
    ]);
    if (fresh.isEmpty) return;
    final gaps = stagger.sampleGaps(fresh.length);
    var offset = Duration.zero;
    for (var i = 0; i < fresh.length; i++) {
      offset += gaps[i];
      seedIfAbsent(fresh[i], from.add(offset));
    }
  }

  /// The instant [key] is next eligible to publish, or `null` if untracked.
  DateTime? dueAt(String key) => _nextDueAt[key];

  /// Whether [key] is registered and its next-due time is at or before [now].
  bool isDue(String key, DateTime now) {
    final due = _nextDueAt[key];
    return due != null && !now.isBefore(due);
  }

  /// The subset of [keys] due at or before [horizon], ordered by their own
  /// due-time (most overdue first), ties broken by key so the order is total.
  ///
  /// Most-overdue-first is what keeps the in-cycle stagger nearly free: the
  /// circle that has waited longest takes the zero gap and the freshest one
  /// absorbs the delay, so staggering shifts WHICH circle waits rather than
  /// adding to the worst-case inter-publish gap. Because every due-time is an
  /// independent CSPRNG sample, this ordering is itself randomised — it is not
  /// a stable, fingerprintable circle order.
  ///
  /// [horizon] is normally the cycle start plus the stagger budget, so circles
  /// seeded a few seconds apart are all serviced within the SAME cycle instead
  /// of slipping a whole polling interval.
  List<String> dueKeysUpTo(Iterable<String> keys, DateTime horizon) {
    return <String>[
      for (final key in keys)
        if (_nextDueAt[key] case final at? when !at.isAfter(horizon)) key,
    ]..sort((a, b) {
      final byTime = _nextDueAt[a]!.compareTo(_nextDueAt[b]!);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  }

  /// Records a publish at [now] and re-arms [key] a FRESH [nextIntervalSecs]
  /// into the future. Rearming off `now` (not off the old due-time) means a
  /// slow cycle never accumulates drift, and each circle's cadence stays
  /// independent because [nextIntervalSecs] is sampled independently per call.
  void markPublished(String key, DateTime now, int nextIntervalSecs) {
    _nextDueAt[key] = now.add(Duration(seconds: nextIntervalSecs));
  }

  /// Drops any tracked circle not in [currentKeys] (left / blocked / orphaned /
  /// removed), bounding memory and ensuring a later rejoin gets a genuinely
  /// fresh phase rather than a stale one.
  void pruneToKeys(Set<String> currentKeys) {
    _nextDueAt.removeWhere((key, _) => !currentKeys.contains(key));
  }

  /// Number of circles currently tracked.
  int get length => _nextDueAt.length;

  @visibleForTesting
  Map<String, DateTime> get nextDueForTest => Map.of(_nextDueAt);
}

/// The earliest instant the next circle of a background publish cycle may
/// publish — or `null` when this cycle's stagger budget is spent.
///
/// Two constraints, and the second is the one that actually holds the line:
///
/// * never before the circle's own [dueAt] (its independent cadence), and
/// * never within [gap] of the previous publish's **actual** start.
///
/// Measuring the gap from the ACTUAL previous start rather than from a
/// pre-computed schedule is load-bearing. A schedule of fixed slots collapses
/// the moment one publish overruns its slot: the overrunning publish pushes
/// its successor late, the successor's own slot has already passed, and the
/// one after that fires at its original slot — arbitrarily close behind. The
/// running measurement cannot be compressed that way, so the >1 s separation
/// survives a slow relay, a slow encrypt, or a stalled GPS fix.
///
/// `null` (slot past [deadline]) means "leave the rest due and let the next
/// master tick take them", which is strictly better than compressing the gaps:
/// a deferred circle publishes late, a compressed one publishes with a
/// `created_at` that links it to its sibling forever.
///
/// [phaseStart] is the fallback for an untracked key, so a circle with no
/// recorded due-time is treated as due now rather than skipped.
DateTime? nextBackgroundPublishSlot({
  required DateTime? dueAt,
  required DateTime? lastPublishStartedAt,
  required Duration gap,
  required DateTime phaseStart,
  required DateTime deadline,
}) {
  var slot = dueAt ?? phaseStart;
  if (lastPublishStartedAt != null) {
    final earliest = lastPublishStartedAt.add(gap);
    if (earliest.isAfter(slot)) slot = earliest;
  }
  return slot.isAfter(deadline) ? null : slot;
}
