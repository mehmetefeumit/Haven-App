/// Durable "leave in progress" markers and launch-resume for the REV-1 leaver
/// backstop (driver 2).
///
/// ## Problem
///
/// Under live-sync a departing member publishes a `SelfRemove` and then runs a
/// bounded backstop — re-issuing a fresh SelfRemove until it observes its own
/// removal — before `complete_leave` wipes its MLS state (see
/// `leaver_backstop.dart`). If the process is killed mid-backstop (crash, OS
/// kill, force-quit) the leave is left half-finished: the leaver is still a
/// member of the group but is no longer trying to leave. Without a durable
/// record the returning leaver would silently remain a stale roster ghost.
///
/// ## Solution
///
/// This service records, in [SharedPreferences], the set of circles whose leave
/// is in progress. Each entry is the circle's **public `nostr_group_id`** in
/// lowercase hex — the same relay-routing identifier that already appears in
/// the `["h", …]` tag of every kind:445 event the circle emits. It is NEVER the
/// MLS group id, a pubkey, or any secret material (Haven privacy rule — no such
/// data in plaintext storage); the `nostr_group_id` is the least-sensitive
/// stable handle that still lets the launch resume map a marker to its circle.
///
/// ### Set/clear ordering (crash-safe)
///
/// 1. `markLeaving` SET the marker BEFORE the backstop's first re-issue.
/// 2. `clearLeaving` CLEAR the marker ONLY AFTER `complete_leave` has wiped the
///    leaver's MLS state for that circle.
/// 3. A crash or thrown exception therefore leaves the marker SET.
///
/// Both writes are best-effort: a [SharedPreferences] failure is logged
/// generically and never blocks the leave (the primary objective).
///
/// ### Launch resume
///
/// On the next launch `resumePendingLeaves` re-runs the leave for every pending
/// circle that is still present, then clears the marker once the leave
/// completes (`leaveCircle` itself handles both the still-a-member re-issue and
/// the already-removed orphan-wipe, so no separate membership probe is needed).
/// A marker whose circle is already gone (the leave completed and wiped before
/// the crash) is cleared without redoing anything. A resume that still fails
/// keeps the marker for the next launch.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the durable set of in-progress leaves.
///
/// The value is a `List<String>` of lowercase-hex `nostr_group_id`s. It NEVER
/// holds an MLS group id, pubkey, relay URL, or any secret material.
const String kPendingLeaveKey = 'haven.security.pending_leaves';

/// Records, clears, and resumes durable leaver-backstop intent.
///
/// Inject [SharedPreferences] for testability; production callers obtain one
/// via [SharedPreferences.getInstance] and construct directly.
class PendingLeaveService {
  /// Creates the service over the given [SharedPreferences].
  const PendingLeaveService({required SharedPreferences prefs})
    : _prefs = prefs;

  final SharedPreferences _prefs;

  /// Lowercase, 2-digit-per-byte hex of [bytes] — the marker encoding.
  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  // ---------------------------------------------------------------------------
  // Marker access
  // ---------------------------------------------------------------------------

  /// The set of `nostr_group_id` hexes with a leave in progress.
  Set<String> get pendingLeaves =>
      (_prefs.getStringList(kPendingLeaveKey) ?? const <String>[]).toSet();

  /// Whether a leave is in progress for the circle with [nostrGroupId].
  bool isLeaving(List<int> nostrGroupId) =>
      pendingLeaves.contains(_hex(nostrGroupId));

  /// Marks the circle with [nostrGroupId] as leave-in-progress.
  ///
  /// Call BEFORE the backstop's first re-issue so a crash leaves it set.
  /// Best-effort — a write failure is logged and does not rethrow.
  Future<void> markLeaving(List<int> nostrGroupId) async {
    final set = pendingLeaves..add(_hex(nostrGroupId));
    await _write(set);
  }

  /// Clears the leave-in-progress marker for the circle with [nostrGroupId].
  ///
  /// Call ONLY AFTER `complete_leave` wiped the leaver's MLS state.
  /// Best-effort — a write failure is logged and does not rethrow.
  Future<void> clearLeaving(List<int> nostrGroupId) =>
      _clearHex(_hex(nostrGroupId));

  Future<void> _clearHex(String hex) async {
    final set = pendingLeaves..remove(hex);
    await _write(set);
  }

  Future<void> _write(Set<String> set) async {
    try {
      await _prefs.setStringList(kPendingLeaveKey, set.toList());
    } on Object catch (e) {
      // A marker write failure must never block the leave. Log only the type —
      // never `e` (SharedPreferences errors could echo the stored value).
      debugPrint(
        '[PendingLeave] WARNING: failed to persist leave markers: '
        '${e.runtimeType}',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Launch resume
  // ---------------------------------------------------------------------------

  /// Finishes every leave interrupted by a crash.
  ///
  /// For each pending marker:
  /// - if no live circle matches it → the leave already completed and wiped;
  ///   the stale marker is cleared;
  /// - otherwise the leave is re-run via [CircleService.leaveCircle] (which,
  ///   when still a member, re-enters the bounded backstop, and when already
  ///   removed, orphan-wipes) and the marker is cleared once it completes.
  ///
  /// A resume that still fails keeps the marker for the next launch.
  /// Best-effort throughout — a failure to enumerate circles simply defers to
  /// the next launch. [selfPubkeyHex] is the leaver's own identity pubkey.
  Future<void> resumePendingLeaves({
    required CircleService circleService,
    required String selfPubkeyHex,
  }) async {
    final pending = pendingLeaves;
    if (pending.isEmpty) return;

    final List<Circle> circles;
    try {
      circles = await circleService.getVisibleCircles();
    } on Object catch (e) {
      debugPrint(
        '[PendingLeave] resume: could not list circles: ${e.runtimeType}',
      );
      return; // retry next launch
    }

    // Map each live circle by its public nostr_group_id hex.
    final byHex = <String, Circle>{
      for (final c in circles) _hex(c.nostrGroupId): c,
    };

    for (final hex in pending) {
      final circle = byHex[hex];
      if (circle == null) {
        // No live circle → the interrupted leave already wiped before the
        // crash. Clear the stale marker.
        await _clearHex(hex);
        continue;
      }

      try {
        debugPrint('[PendingLeave] resuming a leave');

        // Re-run the leave unconditionally — leaveCircle -> planLeave already
        // resolves both cases with no separate membership probe: still a member
        // -> republish the SelfRemove and re-enter the bounded backstop;
        // already removed -> orphan-wipe. Either path finishes the leave and
        // wipes the leaver's MLS state.
        await circleService.leaveCircle(
          mlsGroupId: circle.mlsGroupId,
          selfPubkeyHex: selfPubkeyHex,
        );
        await _clearHex(hex);
      } on Object catch (e) {
        debugPrint(
          '[PendingLeave] resume for a circle failed: ${e.runtimeType}',
        );
        // Keep the marker so the next launch retries.
      }
    }
  }
}
