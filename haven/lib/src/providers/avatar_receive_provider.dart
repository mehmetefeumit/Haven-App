/// "Receive avatars" preference (§7.5 privacy toggle).
///
/// When OFF, [LocationSharingService._ingestAvatar] is short-circuited BEFORE
/// any FFI decode or disk store so that:
///   1. An image decoder never runs on attacker-controlled bytes.
///   2. No faces are stored at rest.
///
/// Member tiles and map markers continue to render initials normally.
///
/// Mirrors the exact pattern of [AvatarDataSaverNotifier] /
/// [avatarDataSaverProvider] so the behaviour is predictable and testable
/// without extra infrastructure.
///
/// Security design:
/// - Stored in [SharedPreferences] (not secure storage) — the preference is
///   not secret and must survive process restarts without async keyring IO.
/// - Defaults to `true` (receiving enabled) on first launch so the
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

/// Key under which the "receive avatars" preference is stored.
const String kAvatarReceiveKey = 'haven.avatar.receive_enabled';

// ---------------------------------------------------------------------------
// Notifier + provider
// ---------------------------------------------------------------------------

/// Notifier for the "Receive avatars" privacy toggle.
///
/// Loads from [SharedPreferences] on construction (defaulting to `true`) and
/// writes through on mutation. Exposed as [avatarReceiveProvider].
class AvatarReceiveNotifier extends StateNotifier<bool> {
  /// Creates an [AvatarReceiveNotifier].
  ///
  /// The optional [prefs] parameter is a test seam that injects a fake
  /// [SharedPreferences] so tests can skip real disk IO. Production callers
  /// omit it and the notifier fetches the real singleton on init.
  AvatarReceiveNotifier({SharedPreferences? prefs})
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
        state = p.getBool(kAvatarReceiveKey) ?? true;
      }
    } on Object catch (e) {
      debugPrint('[AvatarReceive] load failed: ${e.runtimeType}');
    }
  }

  /// Enables or disables incoming avatar ingestion.
  ///
  /// Persists to [SharedPreferences] before updating the in-memory state so
  /// that a process kill between the two cannot leave them out of sync.
  Future<void> setEnabled({required bool enabled}) async {
    try {
      final p = await _prefs;
      await p.setBool(kAvatarReceiveKey, enabled);
      if (mounted) state = enabled;
    } on Object catch (e) {
      debugPrint('[AvatarReceive] write failed: ${e.runtimeType}');
    }
  }
}

/// Provider exposing whether avatar receiving is enabled.
///
/// When `false`, [LocationSharingService] short-circuits [_ingestAvatar]
/// before any FFI decode or disk store. Member tiles render initials.
/// Defaults to `true` on first launch.
final avatarReceiveProvider =
    StateNotifierProvider<AvatarReceiveNotifier, bool>(
      (ref) => AvatarReceiveNotifier(),
    );
