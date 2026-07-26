/// Per-circle publish-due bookkeeping for the background isolate.
///
/// Decorrelation (privacy): the app must NOT publish a kind-445 location to
/// every circle on one shared tick — a relay that sees several distinct `#h`
/// (nostr_group_id) tags all receiving an event within the same instant, every
/// cycle, can correlate those otherwise-unlinkable pseudonymous circles as one
/// device. The foreground breaks this with one independent [JitteredScheduler]
/// per circle; the background isolate — which runs a single periodic
/// `onRepeatEvent` cycle — breaks it by tracking an INDEPENDENT next-due time
/// per circle here and publishing only the circles whose own time has come.
///
/// This is a pure, FFI-free value object so the decorrelation logic is unit
/// testable without the Rust bridge or a live foreground-service (the
/// surrounding [background task handler] is inherently bridge-bound and cannot
/// run under `flutter test`).
library;

import 'package:flutter/foundation.dart';

/// Tracks, per circle key, the wall-clock time at which that circle is next
/// eligible to publish. Keys are opaque to this class; callers use the public
/// `nostr_group_id` hex (never the real MLS group id — CLAUDE.md Rule 4).
class PerCircleDueTracker {
  final Map<String, DateTime> _nextDueAt = {};

  /// Registers [key] with an initial due-time IF it is not already tracked.
  ///
  /// Idempotent: an already-tracked circle keeps its existing schedule (so a
  /// circle that has been publishing on its own cadence is never yanked back
  /// to a fresh phase just because it was seen again this cycle). The caller
  /// chooses [initialDue]: the background seeds `now` ("due now") so the first
  /// cycle after it takes over from the foreground publishes promptly — bounding
  /// a circle's worst-case inter-publish gap across the handoff to one publish
  /// interval, which keeps the shortened kind-445 TTL's no-gap invariant intact
  /// (see `LOCATION_MESSAGE_RETENTION_SECS`).
  void seedIfAbsent(String key, DateTime initialDue) {
    _nextDueAt.putIfAbsent(key, () => initialDue);
  }

  /// Whether [key] is registered and its next-due time is at or before [now].
  bool isDue(String key, DateTime now) {
    final due = _nextDueAt[key];
    return due != null && !now.isBefore(due);
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
