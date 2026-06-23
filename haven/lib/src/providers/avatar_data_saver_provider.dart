/// Avatar data-saver preference and anti-entropy interval constants (M3).
///
/// Controls how often the own avatar is re-shared into every circle to
/// heal dropped chunks, relay churn, and late joiners the epoch trigger
/// missed (§5.7 periodic anti-entropy).
///
/// Security design:
/// - Stored in [SharedPreferences] (not secure storage) — the setting is not
///   secret and must survive process restarts without async keyring IO.
/// - Two named constants are the ONLY place interval durations are defined;
///   owner changes one constant, every consumer picks it up automatically.
/// - No raw errors reach the UI: SharedPreferences failures are swallowed
///   to [debugPrint] and a safe default is returned.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Named constants (§5.7 DEC-2 / owner-tunable)
// ---------------------------------------------------------------------------

/// Default avatar anti-entropy interval (§5.7 DEC-2).
///
/// Every [avatarAntiEntropyInterval], the own avatar is re-shared into
/// every accepted circle — healing dropped chunks and relay churn. Jittered
/// by the scheduler; this is the nominal (un-jittered) value.
const Duration avatarAntiEntropyInterval = Duration(hours: 24);

/// Data-saver anti-entropy interval.
///
/// When the data-saver toggle is on, the re-share period is lengthened to
/// reduce mobile data use. Trades quicker convergence for lower bandwidth.
const Duration avatarAntiEntropyIntervalDataSaver = Duration(hours: 72);

// ---------------------------------------------------------------------------
// SharedPreferences key
// ---------------------------------------------------------------------------

/// Key under which the data-saver preference is stored.
const String kAvatarDataSaverKey = 'haven.avatar.data_saver';

// ---------------------------------------------------------------------------
// Notifier + provider
// ---------------------------------------------------------------------------

/// Notifier for the avatar data-saver toggle.
///
/// Loads from [SharedPreferences] on construction (defaulting to `false`) and
/// writes through on mutation. Exposed as [avatarDataSaverProvider].
class AvatarDataSaverNotifier extends StateNotifier<bool> {
  /// Creates an [AvatarDataSaverNotifier].
  ///
  /// The optional [prefs] parameter is a test seam that injects a fake
  /// [SharedPreferences] so tests can skip real disk IO. Production callers
  /// omit it and the notifier fetches the real singleton on init.
  AvatarDataSaverNotifier({SharedPreferences? prefs})
    : _prefsOverride = prefs,
      super(false) {
    _load();
  }

  final SharedPreferences? _prefsOverride;

  Future<SharedPreferences> get _prefs async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  Future<void> _load() async {
    try {
      final p = await _prefs;
      if (mounted) {
        state = p.getBool(kAvatarDataSaverKey) ?? false;
      }
    } on Object catch (e) {
      debugPrint('[AvatarDataSaver] load failed: ${e.runtimeType}');
    }
  }

  /// Enables or disables the data-saver mode.
  ///
  /// Persists to [SharedPreferences] before updating the in-memory state so
  /// that a process kill between the two cannot leave them out of sync.
  Future<void> setEnabled({required bool enabled}) async {
    try {
      final p = await _prefs;
      await p.setBool(kAvatarDataSaverKey, enabled);
      if (mounted) state = enabled;
    } on Object catch (e) {
      debugPrint('[AvatarDataSaver] write failed: ${e.runtimeType}');
    }
  }

  /// Returns the effective anti-entropy interval given the current state.
  Duration get effectiveInterval =>
      state ? avatarAntiEntropyIntervalDataSaver : avatarAntiEntropyInterval;
}

/// Provider exposing whether avatar data-saver mode is enabled.
///
/// When `true`, the anti-entropy re-share cadence is lengthened from 24 h to
/// 72 h. Defaults to `false` (normal cadence) on first launch.
final avatarDataSaverProvider =
    StateNotifierProvider<AvatarDataSaverNotifier, bool>(
      (ref) => AvatarDataSaverNotifier(),
    );
