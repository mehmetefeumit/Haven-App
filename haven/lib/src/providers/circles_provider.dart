/// Providers for circle state management.
///
/// Provides reactive access to circles and selection state for the
/// draggable bottom sheet interface.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';

/// Provider for the list of visible circles.
///
/// Fetches circles from [CircleService] and makes them available
/// reactively throughout the app.
///
/// Returns an empty list if the service fails to initialize (e.g., keyring
/// not available on the platform). This allows the UI to display gracefully
/// even when the backend is unavailable.
final circlesProvider = FutureProvider<List<Circle>>((ref) async {
  final circleService = ref.read(circleServiceProvider);
  try {
    return await circleService.getVisibleCircles();
  } on CircleServiceException catch (e) {
    // Log the error but return empty list for graceful degradation
    debugPrint('CircleService error: ${e.runtimeType}');
    return [];
  }
  // FFI errors may not extend Exception, so we need a bare catch clause.
  // This handles keyring init failures, storage errors, and MLS errors.
  // ignore: avoid_catches_without_on_clauses
  catch (e) {
    debugPrint('Failed to load circles: ${e.runtimeType}');
    return [];
  }
});

/// The local MLS epoch for one circle, or `null` when it cannot be read.
///
/// The epoch is a monotonic commit counter: it advances by exactly one for
/// every applied MLS commit (a membership change or a key update). Members of
/// a converged circle all report the same number, so a persistent mismatch
/// between two devices is the signature of the desync that stops messages
/// decrypting. The circle-details sheet surfaces it for that diagnosis.
///
/// Resolves to `null` — never to an error — when there is no live MLS group
/// for the circle (legacy/orphaned pre-cutover rows, see
/// [CircleLegacyStatus.isLegacyOrphaned]) or the manager is unavailable.
/// Callers hide the epoch entirely in that case rather than surfacing a
/// failure, so the line degrades to a bare member count.
///
/// Keyed by [Circle], whose equality and `hashCode` are both derived from
/// `mlsGroupId` alone — so the cache entry is per-group and survives roster
/// changes. `autoDispose` makes each re-open of the sheet re-read the epoch
/// instead of serving a stale number.
final AutoDisposeFutureProviderFamily<int?, Circle> circleEpochProvider =
    FutureProvider.autoDispose.family<int?, Circle>((ref, circle) async {
  final circleService = ref.read(circleServiceProvider);
  if (circleService is! NostrCircleService) return null;
  try {
    final manager = await circleService.getCircleManagerFfi();
    final epoch = await manager.groupEpoch(mlsGroupId: circle.mlsGroupId);
    return epoch.toInt();
  }
  // FFI errors may not extend Exception, so a bare catch clause is required.
  // A missing group is an expected outcome here, not an anomaly.
  // ignore: avoid_catches_without_on_clauses
  catch (e) {
    debugPrint('Failed to read circle epoch: ${e.runtimeType}');
    return null;
  }
});

/// Stores the MLS group ID of the currently selected circle.
///
/// Write to this provider to change the selection. The full [Circle]
/// object is derived by [selectedCircleProvider], which always reflects
/// the latest member list from [circlesProvider].
final selectedCircleIdProvider = StateProvider<List<int>?>((ref) => null);

/// Provider for the currently selected circle.
///
/// Derives the full [Circle] from [circlesProvider] by matching
/// [selectedCircleIdProvider], so a read here always carries an
/// up-to-date member list — even after MLS group state changes
/// (e.g., a new member joining via commit).
///
/// Watching this alone does NOT rebuild on a roster change: [Circle]
/// compares by `mlsGroupId` only, so Riverpod treats a same-circle,
/// fewer-members recomputation as unchanged and notifies nobody. Widgets
/// that render members must also watch [circlesProvider], whose fresh
/// list always notifies — that is what propagates a removal to the tree.
///
/// Returns `null` when no circle is selected or when the selected
/// circle is no longer in the visible list (e.g., after leaving).
final selectedCircleProvider = Provider<Circle?>((ref) {
  final selectedId = ref.watch(selectedCircleIdProvider);
  if (selectedId == null) return null;

  final circlesAsync = ref.watch(circlesProvider);
  return circlesAsync.whenOrNull(
    data: (circles) =>
        circles.where((c) => listEquals(c.mlsGroupId, selectedId)).firstOrNull,
  );
});

/// Whether the circle dropdown selector is currently expanded.
final circleDropdownOpenProvider = StateProvider<bool>((ref) => false);
