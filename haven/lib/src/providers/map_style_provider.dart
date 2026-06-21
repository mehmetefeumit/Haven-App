/// Map-style selection state.
///
/// Holds the user's chosen basemap style and persists it to
/// [SharedPreferences], exposed as a [StateNotifierProvider] so the map can
/// react immediately. Mirrors `theme_mode_provider.dart`:
///
/// * the choice is stored as a string under [kMapStyleKey];
/// * each mutation awaits the storage write **before** updating in-memory
///   state, so a process kill between the two cannot desync them;
/// * the provider is overridden at the root in `main.dart` with the value
///   pre-loaded via [loadInitialMapStyle] for flicker-free startup.
///
/// The active [TileProviderConfig] is derived from the selection at render
/// time by [MapStyleSelection.resolve], which the brightness-keyed
/// `tileProviderConfigProvider` calls (so the "Auto" style follows the app's
/// live light/dark theme without this provider depending on `BuildContext`).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/constants/tiles.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key under which the selected map style is stored.
const String kMapStyleKey = 'haven.map.style';

/// Persisted sentinel for the theme-following "Auto" selection.
const String _autoStyleId = 'auto';

/// The user's basemap-style choice.
///
/// Either [MapStyleSelection.auto] (follow the app's light/dark theme) or an
/// explicit [MapStyleSelection.style] wrapping a [TileProviderConfig.id] from
/// [kTileStyleCatalog]. Resolve it to a concrete config with [resolve].
@immutable
class MapStyleSelection {
  /// Follows the app's light/dark theme: [stadiaAlidadeSmooth] in light,
  /// [stadiaAlidadeSmoothDark] in dark.
  const MapStyleSelection.auto() : _styleId = null;

  /// Pins an explicit style by its [TileProviderConfig.id].
  const MapStyleSelection.style(String styleId) : _styleId = styleId;

  /// The pinned style id, or `null` for [MapStyleSelection.auto].
  final String? _styleId;

  /// Whether this selection follows the app theme rather than a fixed style.
  bool get isAuto => _styleId == null;

  /// The persisted identifier: a [TileProviderConfig.id], or `'auto'`.
  String get rawId => _styleId ?? _autoStyleId;

  /// Resolves this selection to a concrete [TileProviderConfig].
  ///
  /// [MapStyleSelection.auto] resolves by [brightness]; an explicit selection
  /// looks its id up in [kTileStyleCatalog]. An unknown id (e.g. one written by
  /// a future build) falls back to the brightness-appropriate Alidade canvas so
  /// the map never renders blank tiles and never strands a dark-theme user on a
  /// glaring light basemap.
  TileProviderConfig resolve(Brightness brightness) {
    final autoDefault = brightness == Brightness.dark
        ? stadiaAlidadeSmoothDark
        : stadiaAlidadeSmooth;
    if (isAuto) return autoDefault;
    return kTileStyleCatalog.firstWhere(
      (config) => config.id == _styleId,
      orElse: () => autoDefault,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MapStyleSelection && other._styleId == _styleId;

  @override
  int get hashCode => _styleId.hashCode;
}

/// Serializes [selection] to its persisted string form.
String _encode(MapStyleSelection selection) => selection.rawId;

/// Deserializes a persisted string back to a [MapStyleSelection].
///
/// `null`, `'auto'`, and any unrecognised id (a corrupted entry or one written
/// by a future build) all fall back to [MapStyleSelection.auto] so startup
/// never throws and never renders an unknown style.
MapStyleSelection _decode(String? raw) {
  if (raw == null || raw == _autoStyleId) return const MapStyleSelection.auto();
  final isKnown = kTileStyleCatalog.any((config) => config.id == raw);
  return isKnown
      ? MapStyleSelection.style(raw)
      : const MapStyleSelection.auto();
}

/// Loads the persisted [MapStyleSelection] from [SharedPreferences].
///
/// Awaited in `main.dart` before `runApp` so the first frame renders the
/// user's chosen style. Returns [MapStyleSelection.auto] when nothing is
/// stored.
Future<MapStyleSelection> loadInitialMapStyle() async {
  final prefs = await SharedPreferences.getInstance();
  return _decode(prefs.getString(kMapStyleKey));
}

/// [StateNotifier] holding the user's selected map style.
///
/// Mutations persist to [SharedPreferences] before updating in-memory state.
class MapStyleController extends StateNotifier<MapStyleSelection> {
  /// Creates a controller seeded with [initial].
  ///
  /// In production the root [ProviderScope] overrides the provider with the
  /// value pre-loaded by [loadInitialMapStyle]. Tests may pass any value.
  MapStyleController(super.initial);

  /// Persists [selection] and updates the in-memory state.
  ///
  /// No-op if [selection] equals the current state — avoids a redundant disk
  /// write when a user re-taps the already-selected option.
  Future<void> setStyle(MapStyleSelection selection) async {
    if (state == selection) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kMapStyleKey, _encode(selection));
    if (!mounted) return;
    state = selection;
  }
}

/// Provides the [MapStyleController] and the current [MapStyleSelection].
///
/// The default factory yields [MapStyleSelection.auto]; the production root
/// overrides this with a value pre-loaded from [SharedPreferences] before
/// `runApp` to guarantee no style flicker on cold start.
final mapStyleControllerProvider =
    StateNotifierProvider<MapStyleController, MapStyleSelection>(
      (ref) => MapStyleController(const MapStyleSelection.auto()),
    );
