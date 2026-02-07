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
    // ignore: avoid_catches_without_on_clauses
  } catch (e) {
    // Catch ALL errors including FFI errors (which may not extend Exception).
    // This handles initialization errors (keyring, storage, MLS errors, etc.)
    debugPrint('Failed to load circles: $e');
    return [];
  }
});

/// Provider for the currently selected circle.
///
/// Used by the bottom sheet to track which circle's members to display.
/// Returns `null` when no circle is selected.
final selectedCircleProvider = StateProvider<Circle?>((ref) => null);
