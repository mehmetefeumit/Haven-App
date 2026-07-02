/// Provider for periodic MLS key rotation (MIP-02/03).
///
/// Queries MDK for groups where the user's leaf node key material is stale
/// or where the post-join self-update was never completed, then performs
/// a self-update for each. Designed to run on a 1-hour timer and on app
/// resume.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:haven/src/providers/service_providers.dart';

/// Whether the LEADERLESS periodic + post-join self-update is enabled.
///
/// **Disabled (M5).** Leaderless self-update is the dominant generator of the
/// MLS epoch-fork: from a shared epoch N two members each stage their own
/// self-update commit and eagerly merge it, diverging permanently. Disabling it
/// removes that generator. The cost is a forward-secrecy / post-compromise
/// deviation (MIP-02 post-join MUST and MIP-03 periodic rotation) accepted by
/// the project owner — see SECURITY.md and MARMOT_PROTOCOL_KNOWLEDGE.md.
///
/// This is the single source of truth: call sites gate on this const rather
/// than deleting [selfUpdateProvider], so the provider body stays live (and
/// test-covered) and can be re-enabled once M3's settle-window + M4's
/// adopt-winner convergence make concurrent self-updates fork-safe.
const enablePeriodicSelfUpdate = false;

/// Self-update rotation threshold in seconds (1 hour).
///
/// Groups whose last self-update is older than this — or where the post-join
/// self-update was never completed — will be rotated.
const selfUpdateThresholdSecs = 3600;

/// Queries groups needing key rotation and performs a self-update for each.
///
/// Returns the number of groups successfully updated. Failures for individual
/// groups are logged but do not prevent other groups from being updated.
///
/// Trigger via `ref.invalidate(selfUpdateProvider)` + `ref.read(...)`.
final selfUpdateProvider = FutureProvider<int>((ref) async {
  final circleService = ref.read(circleServiceProvider);

  List<List<int>> groupIds;
  try {
    groupIds = await circleService.groupsNeedingSelfUpdate(
      selfUpdateThresholdSecs,
    );
  } on Object catch (e) {
    debugPrint('Self-update query failed: ${e.runtimeType}');
    return 0;
  }

  if (groupIds.isEmpty) return 0;

  debugPrint('Self-update: ${groupIds.length} group(s) need rotation');

  var updated = 0;
  for (final groupId in groupIds) {
    try {
      await circleService.selfUpdate(groupId);
      updated++;
    } on Object catch (e) {
      // Individual failures must not block remaining groups.
      debugPrint('Self-update failed for a group: ${e.runtimeType}');
    }
  }

  debugPrint('Self-update: $updated group(s) rotated');
  return updated;
});
