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
    debugPrint('Self-update query failed: $e');
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
      debugPrint('Self-update failed for a group: $e');
    }
  }

  debugPrint('Self-update: $updated group(s) rotated');
  return updated;
});
