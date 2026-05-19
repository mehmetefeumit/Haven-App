/// Theme-mode state provider.
///
/// Persists the user's theme preference (system default, light, or dark) to
/// [SharedPreferences] and exposes it as a [StateNotifierProvider] so any
/// widget — most importantly the root [MaterialApp] — can react to changes
/// immediately without a restart.
///
/// # Persistence contract
///
/// The mode is stored as a string under [kThemeModeKey]. Each mutation awaits
/// the [SharedPreferences.setString] write **before** updating the in-memory
/// state, so a process kill between storage and memory cannot leave the two
/// out of sync (mirrors the onboarding provider's invariant).
///
/// # Flicker-free startup
///
/// The provider is overridden at the root of the tree in `main.dart` with
/// the value pre-loaded via [loadInitialThemeMode] before `runApp`. The
/// first frame therefore renders in the correct brightness with no flash
/// of the wrong theme.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// [SharedPreferences] key under which the selected [ThemeMode] is stored.
const String kThemeModeKey = 'haven.theme.mode';

/// Serializes a [ThemeMode] to a stable, persisted string identifier.
String _encode(ThemeMode mode) {
  switch (mode) {
    case ThemeMode.system:
      return 'system';
    case ThemeMode.light:
      return 'light';
    case ThemeMode.dark:
      return 'dark';
  }
}

/// Deserializes a persisted string back to a [ThemeMode].
///
/// Unknown or `null` values fall back to [ThemeMode.system] so a corrupted
/// preferences file (or a value written by a future build) never produces
/// an exception on startup.
ThemeMode _decode(String? raw) {
  switch (raw) {
    case 'light':
      return ThemeMode.light;
    case 'dark':
      return ThemeMode.dark;
    case 'system':
    case null:
    default:
      return ThemeMode.system;
  }
}

/// Loads the persisted [ThemeMode] from [SharedPreferences].
///
/// Intended to be awaited in `main.dart` before `runApp` so the root
/// [MaterialApp] renders the user's chosen brightness on the very first
/// frame. If no value has been stored yet, returns [ThemeMode.system].
Future<ThemeMode> loadInitialThemeMode() async {
  final prefs = await SharedPreferences.getInstance();
  return _decode(prefs.getString(kThemeModeKey));
}

/// [StateNotifier] holding the user's selected [ThemeMode].
///
/// Mutations persist to [SharedPreferences] before updating in-memory state.
class ThemeModeController extends StateNotifier<ThemeMode> {
  /// Creates a controller seeded with [initial].
  ///
  /// In production the root [ProviderScope] overrides the provider with the
  /// value pre-loaded by [loadInitialThemeMode]. Tests may pass any value.
  ThemeModeController(super.initial);

  /// Persists [mode] and updates the in-memory state.
  ///
  /// No-op if [mode] equals the current state — avoids a redundant disk
  /// write when a user re-taps the already-selected option.
  Future<void> setMode(ThemeMode mode) async {
    if (state == mode) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kThemeModeKey, _encode(mode));
    if (!mounted) return;
    state = mode;
  }
}

/// Provides the [ThemeModeController] and its current [ThemeMode].
///
/// The default factory yields [ThemeMode.system]; the production root
/// overrides this with a value pre-loaded from [SharedPreferences] before
/// `runApp` to guarantee zero theme flicker on cold start.
final themeModeControllerProvider =
    StateNotifierProvider<ThemeModeController, ThemeMode>(
      (ref) => ThemeModeController(ThemeMode.system),
    );
