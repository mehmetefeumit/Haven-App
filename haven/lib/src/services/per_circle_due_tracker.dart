/// Publish-due bookkeeping for the background isolate's location cycle.
///
/// ## One burst, not one schedule per circle
///
/// Every eligible circle shares one due time, so a cycle publishes them all
/// and the radio wakes once per interval however many circles the user is in.
/// The per-circle schedules this replaced never bought the decorrelation they
/// were written for: the multiplexed `#h` subscription already tells a shared
/// relay which circles this socket watches, and every circle's publish leaves
/// over one publish socket. The honest cost of coalescing is that circles on
/// DISJOINT relay sets now emit the same inter-burst rhythm, so anyone holding
/// two of your circles' archives can tell they belong to the same phone.
///
/// ## What the tracker is still for
///
/// A time PER KEY rather than one timestamp for the whole roster, because the
/// two are not the same map: a circle whose publish FAILED, or which a burst's
/// budget deferred, must stay overdue while its siblings re-arm. What a burst
/// re-arms them onto, though, is one shared instant — see [nextBurstDue] for
/// why a due per circle silently kills the burst-order permutation.
///
/// This class is necessary but NOT sufficient on its own: the caller must also
/// pace what it selects, because a burst's circles are due in the SAME instant
/// and `onRepeatEvent` is a coarse poll (`kBackgroundRepeatInterval`, 72 s).
/// `dueKeysUpTo` returns them ordered for exactly that, and the
/// [PublishStagger] gap between consecutive publishes is what keeps their
/// whole-second `created_at` stamps distinct.
///
/// This is a pure, FFI-free value object so the burst logic is unit testable
/// without the Rust bridge or a live foreground-service (the surrounding
/// [background task handler] is inherently bridge-bound and cannot run under
/// `flutter test`).
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
  /// The background seeds the WHOLE roster at ONE instant, deliberately: a
  /// handoff hands every circle to the same burst, which is the wake the
  /// device pays for either way. [pruneToKeys] empties this map while the
  /// foreground owns publishing, so this seed re-runs on every
  /// foreground→background handoff — and a per-circle seed would therefore
  /// re-scatter the roster into one wake per circle on every one of them.
  /// Seeding together is NOT publishing together: the cycle still holds each
  /// circle a [PublishStagger] gap behind the last
  /// ([nextBackgroundPublishSlot]), which is what keeps their `created_at`
  /// stamps in different whole seconds.
  void seedIfAbsent(String key, DateTime initialDue) {
    _nextDueAt.putIfAbsent(key, () => initialDue);
  }

  /// The instant [key] is next eligible to publish, or `null` if untracked.
  DateTime? dueAt(String key) => _nextDueAt[key];

  /// Whether [key] is registered and its next-due time is at or before [now].
  bool isDue(String key, DateTime now) {
    final due = _nextDueAt[key];
    return due != null && !now.isBefore(due);
  }

  /// The subset of [keys] due at or before [horizon], ordered by their own
  /// due-time (most overdue first), ties broken by the order [keys] arrives
  /// in so the order is total.
  ///
  /// Most-overdue-first is what keeps the in-cycle stagger nearly free: the
  /// circle that has waited longest takes the zero gap and the freshest one
  /// absorbs the delay, so staggering shifts WHICH circle waits rather than
  /// adding to the worst-case inter-publish gap.
  ///
  /// Ties are the NORM — a burst seeds and re-arms its circles onto ONE due
  /// ([nextBurstDue]) — which makes the tie-break the burst order, so it may
  /// not be a property of the circles themselves. Breaking by key would make
  /// one circle permanently the un-delayed one and its sibling permanently
  /// ~5 s behind: a stable relationship between their `created_at`s, i.e. the
  /// second-order fingerprint [PublishStagger.shuffled] exists to prevent. The
  /// caller therefore owns the tie order and passes a CSPRNG permutation.
  ///
  /// [horizon] is normally the cycle start plus the stagger budget, so circles
  /// whose due-times sit a few seconds apart are all serviced within the SAME
  /// cycle instead of slipping a whole polling interval.
  List<String> dueKeysUpTo(Iterable<String> keys, DateTime horizon) {
    final due = <String>[
      for (final key in keys)
        if (_nextDueAt[key] case final at? when !at.isAfter(horizon)) key,
    ];
    // `List.sort` is not stable, so the caller's order is carried explicitly
    // rather than relied upon.
    final arrival = <String, int>{
      for (var i = 0; i < due.length; i++) due[i]: i,
    };
    return due
      ..sort((a, b) {
        final byTime = _nextDueAt[a]!.compareTo(_nextDueAt[b]!);
        return byTime != 0 ? byTime : arrival[a]!.compareTo(arrival[b]!);
      });
  }

  /// The earliest due-time among [keys], or `null` when none of them is
  /// tracked.
  ///
  /// This is what the background cycle aims its single platform location
  /// request at (`nextFixRequestInterval`): the FIRST circle that needs a fix
  /// decides when the receiver runs, because aiming at any later due-time
  /// starves the earlier circle by the difference.
  ///
  /// Asked about a SUBSET on purpose. For the circles it is about to publish
  /// the cycle already knows something this map does not — the slot and the
  /// interval it pre-sampled for them — so it folds those projections in
  /// itself and asks here only about the rest. An overdue circle is reported at
  /// its own past due-time rather than clamped to the present: that is exactly
  /// the case the request's platform floor exists for.
  DateTime? earliestDue(Iterable<String> keys) {
    DateTime? earliest;
    for (final key in keys) {
      final at = _nextDueAt[key];
      if (at != null && (earliest == null || at.isBefore(earliest))) {
        earliest = at;
      }
    }
    return earliest;
  }

  /// Re-arms every circle a burst has published so far onto the single
  /// [dueAt] its caller derived with [nextBurstDue].
  ///
  /// Called after EACH publish with everything published so far, not once at
  /// the end: a burst can be cut short by a service stop or a foreground
  /// reclaim, and the circles that did go out must be left holding the
  /// schedule that actually happened rather than staying overdue and
  /// republishing seconds later.
  void markBurstPublished(Iterable<String> keys, DateTime dueAt) {
    for (final key in keys) {
      _nextDueAt[key] = dueAt;
    }
  }

  /// Drops any tracked circle not in [currentKeys] (left / blocked / orphaned /
  /// removed), bounding memory and ensuring a later rejoin gets a genuinely
  /// fresh phase rather than a stale one.
  void pruneToKeys(Set<String> currentKeys) {
    _nextDueAt.removeWhere((key, _) => !currentKeys.contains(key));
  }

  /// Number of circles currently tracked.
  int get length => _nextDueAt.length;

  /// Every circle currently on a schedule.
  ///
  /// For the one question a caller cannot phrase as a subset: "is ANYTHING due
  /// soon?" — which the background cycle asks before it re-runs itself for a
  /// fix that arrived mid-cycle, and which must not be answered off a stale
  /// copy of the roster.
  Iterable<String> get trackedKeys => _nextDueAt.keys;

  @visibleForTesting
  Map<String, DateTime> get nextDueForTest => Map.of(_nextDueAt);
}

/// The ONE due-time a burst re-arms every circle it published onto.
///
/// One due, not one per circle, and that is the whole point:
/// `PerCircleDueTracker.dueKeysUpTo` orders by due ascending, so distinct dues
/// make the next burst's order a function of this burst's order. The CSPRNG
/// permutation then becomes dead code after the first burst — the same circle
/// leads every burst for the rest of the session, and the whole-second delta
/// between two circles' `created_at` climbs to a fixed value and prints it
/// every burst. That
/// constant delta is precisely the archive link [PublishStagger] exists to
/// break, so equal dues are not tidiness, they are what keeps the shuffle
/// alive.
///
/// WHICH instant they equal decides two bounds, and only this rule holds both:
///
///  * one interval after the burst's FIRST publish alone lets the circle that
///    published LAST publish again `interval − spread` later — 42 s against
///    the 72 s cadence floor the app discloses;
///  * one interval after its LAST publish alone makes the circle that
///    published FIRST wait `interval + spread` before the next burst starts,
///    plus up to another spread inside it: `168 + 30 + 30 = 228 s`, exactly
///    the retention the no-gap invariant must stay under.
///
/// So: one [interval] after the burst STARTED, never sooner than
/// [minInterval] after it FINISHED. Every circle's realized gap then lands in
/// `[minInterval, interval + spread]` — the disclosed floor at one end and
/// `kLocationPublishMaxInterval + kPublishStaggerMaxSpread` at the other.
DateTime nextBurstDue({
  required DateTime firstPublishStartedAt,
  required DateTime lastPublishStartedAt,
  required Duration interval,
  required Duration minInterval,
}) {
  final fromStart = firstPublishStartedAt.add(interval);
  final floor = lastPublishStartedAt.add(minInterval);
  return floor.isAfter(fromStart) ? floor : fromStart;
}

/// The earliest instant the next circle of a background publish cycle may
/// publish — or `null` when this cycle's stagger budget is spent.
///
/// Two constraints, and the second is the one that actually holds the line:
///
/// * never before the circle's own [dueAt] (the cadence floor the app
///   discloses), and
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
