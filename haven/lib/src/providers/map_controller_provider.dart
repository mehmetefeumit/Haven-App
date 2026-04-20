/// Map controller state providers.
///
/// Hosts the shared [MapController] so that callers outside the map page
/// (e.g. the circles bottom sheet tapping a member) can move the camera
/// without threading a controller through the widget tree, and exposes
/// the user's current obfuscated GPS fix as reactive state for the same
/// reason.
library;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';

/// Shared [MapController] for the app's single map.
///
/// The controller is lazily created on first read and disposed when the
/// enclosing [ProviderScope] tears down, so its lifetime matches the app
/// session rather than any individual widget state. Override in tests to
/// supply a fake controller.
final mapControllerProvider = Provider<MapController>((ref) {
  final controller = MapController();
  ref.onDispose(controller.dispose);
  return controller;
});

/// Latest obfuscated location for the local user, or `null` before the
/// first GPS fix of the session.
///
/// Written by the map page when the location service emits a new
/// position, so any widget that needs the user's own coordinates — for
/// example, tapping the self row in the member list to recenter the
/// map — can read it without reaching into the map page's private state.
final obfuscatedLocationProvider = StateProvider<LatLng?>((_) => null);
