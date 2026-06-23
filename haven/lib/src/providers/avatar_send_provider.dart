/// "Send my avatar" preference (§7.5 privacy toggle).
///
/// When OFF the user's avatar publish paths emit nothing — the stored blob
/// is kept, but no kind-445 avatar events are sent to any circle relay.
/// Off = silent, not removal (no tombstone is broadcast).
///
/// Mirrors the exact pattern of [AvatarDataSaverNotifier] /
/// [avatarDataSaverProvider] so the behaviour is predictable and testable
/// without extra infrastructure.
///
/// Security design:
/// - Stored in [SharedPreferences] (not secure storage) — the preference is
///   not secret and must survive process restarts without async keyring IO.
/// - Defaults to `true` (avatar sharing enabled) on first launch so the
///   feature works out of the box.
/// - No raw errors reach the UI: SharedPreferences failures are swallowed
///   to [debugPrint] and a safe default (`true`) is returned.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// SharedPreferences key
// ---------------------------------------------------------------------------

/// Key under which the "send my avatar" preference is stored.
const String kAvatarSendKey = 'haven.avatar.send_enabled';

// ---------------------------------------------------------------------------
// Notifier + provider
// ---------------------------------------------------------------------------

/// Notifier for the "Send my avatar" privacy toggle.
///
/// Loads from [SharedPreferences] on construction (defaulting to `true`) and
/// writes through on mutation. Exposed as [avatarSendProvider].
class AvatarSendNotifier extends StateNotifier<bool> {
  /// Creates an [AvatarSendNotifier].
  ///
  /// The optional [prefs] parameter is a test seam that injects a fake
  /// [SharedPreferences] so tests can skip real disk IO. Production callers
  /// omit it and the notifier fetches the real singleton on init.
  AvatarSendNotifier({SharedPreferences? prefs})
    : _prefsOverride = prefs,
      super(true) {
    _load();
  }

  final SharedPreferences? _prefsOverride;

  Future<SharedPreferences> get _prefs async =>
      _prefsOverride ?? await SharedPreferences.getInstance();

  Future<void> _load() async {
    try {
      final p = await _prefs;
      if (mounted) {
        // Default true: feature is on unless the user has explicitly turned off.
        state = p.getBool(kAvatarSendKey) ?? true;
      }
    } on Object catch (e) {
      debugPrint('[AvatarSend] load failed: ${e.runtimeType}');
    }
  }

  /// Enables or disables outgoing avatar publishing.
  ///
  /// Persists to [SharedPreferences] before updating the in-memory state so
  /// that a process kill between the two cannot leave them out of sync.
  Future<void> setEnabled({required bool enabled}) async {
    try {
      final p = await _prefs;
      await p.setBool(kAvatarSendKey, enabled);
      if (mounted) state = enabled;
    } on Object catch (e) {
      debugPrint('[AvatarSend] write failed: ${e.runtimeType}');
    }
  }
}

/// Provider exposing whether avatar sending is enabled.
///
/// When `false`, all outgoing avatar publish paths are suppressed — the stored
/// blob is kept but no events are broadcast to circle relays.
/// Defaults to `true` on first launch.
final avatarSendProvider =
    StateNotifierProvider<AvatarSendNotifier, bool>(
      (ref) => AvatarSendNotifier(),
    );
