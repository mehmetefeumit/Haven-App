/// Location state providers.
///
/// Provides reactive access to device location with automatic
/// stream management and cleanup.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/location_service.dart';

/// Stream provider for continuous location updates.
///
/// Automatically manages the location stream subscription and cleanup.
/// Emits new positions when the device moves.
///
/// Usage:
/// ```dart
/// final locationAsync = ref.watch(locationStreamProvider);
/// return locationAsync.when(
///   data: (position) => Text('${position.latitude}, ${position.longitude}'),
///   loading: () => const CircularProgressIndicator(),
///   error: (e, _) => Text('Location error: $e'),
/// );
/// ```
final locationStreamProvider = StreamProvider<Position>((ref) {
  final service = ref.watch(locationServiceProvider);
  return service.getLocationStream();
});
