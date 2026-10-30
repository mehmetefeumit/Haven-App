/// The retired Dart "leave in progress" markers, and their one migration.
///
/// Older builds kept, in [SharedPreferences], the public `nostr_group_id` of
/// every circle whose leave a crash could interrupt, and re-ran the leave from
/// Dart at the next launch. The leave's intent now lives in the core, written
/// before anything else and carried on by the leaver backstop at every wake,
/// so nothing writes a marker any more. A marker an older build left on disk
/// is migrated once: its circle, if still present, is left through the driver
/// — which writes the core's intent — and the key is removed. Each entry is a
/// public `nostr_group_id`, never an MLS group id, a pubkey or a secret.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key for the retired set of in-progress leaves.
///
/// The value is a `List<String>` of lowercase-hex `nostr_group_id`s. It NEVER
/// holds an MLS group id, pubkey, relay URL, or any secret material.
const String kPendingLeaveKey = 'haven.security.pending_leaves';

/// Migrates and clears the retired leave markers.
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

  /// Clears every leave-in-progress marker unconditionally, removing the key
  /// entirely (not merely emptying it).
  ///
  /// Wired into identity deletion, to be called AFTER the caller has already
  /// destroyed every local MLS group (`CircleService.wipeAllMlsState`): once
  /// every group and the signing secret are gone there is nothing left to
  /// resume, and a marker that survived would be a plaintext residue of the
  /// deleted identity's past circle memberships (their public
  /// `nostr_group_id`s). Throws on a prefs failure; the delete path treats
  /// that as best-effort.
  Future<void> clearAll() async {
    await _prefs.remove(kPendingLeaveKey);
  }

  /// Moves every marker an older build left onto the core: each circle
  /// still present is left through [CircleService.leaveCircle], which writes
  /// the core's intent; the key is removed once every present circle's leave
  /// was asked for. A circle gone already needs nothing. If a leave cannot be
  /// asked for, or the app is no longer in front of its user ([inFront],
  /// read before each circle), the key stays for the next start-up.
  Future<void> migrateToCore({
    required CircleService circleService,
    required bool Function() inFront,
  }) async {
    final pending = (_prefs.getStringList(kPendingLeaveKey) ?? const <String>[])
        .toSet();
    if (pending.isEmpty) return;
    final List<Circle> circles;
    try {
      circles = await circleService.getVisibleCircles();
    } on Object catch (e) {
      debugPrint(
        '[PendingLeave] migration: could not list circles: ${e.runtimeType}',
      );
      return;
    }
    for (final circle in circles) {
      if (!pending.contains(_hex(circle.nostrGroupId))) continue;
      if (!inFront()) return;
      try {
        await circleService.leaveCircle(mlsGroupId: circle.mlsGroupId);
      } on Object catch (e) {
        debugPrint('[PendingLeave] migration failed: ${e.runtimeType}');
        return;
      }
    }
    try {
      await _prefs.remove(kPendingLeaveKey);
    } on Object catch (e) {
      // Log only the type: a SharedPreferences error could echo the value.
      debugPrint(
        '[PendingLeave] migration: marker not removed: ${e.runtimeType}',
      );
    }
  }
}
