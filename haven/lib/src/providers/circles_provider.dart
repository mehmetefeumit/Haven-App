/// Providers for circle state management.
///
/// Provides reactive access to circles and selection state for the
/// draggable bottom sheet interface.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/circle_service.dart';

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
    debugPrint('CircleService error: $e');
    return [];
  }
  // FFI errors may not extend Exception, so we need a bare catch clause.
  // This handles keyring init failures, storage errors, and MLS errors.
  // ignore: avoid_catches_without_on_clauses
  catch (e) {
    debugPrint('Failed to load circles: $e');
    return [];
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
/// [selectedCircleIdProvider]. This ensures the selected circle always
/// has an up-to-date member list — even after MLS group state changes
/// (e.g., a new member joining via commit).
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
