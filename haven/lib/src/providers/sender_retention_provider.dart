/// Provider for the sender-controlled location retention preference.
///
/// The retention value (in seconds) is embedded inside every encrypted
/// `LocationMessage` we publish. Receivers honour it as a soft contract
/// — they will drop our last-known-location row from disk after the
/// requested interval has elapsed since our last broadcast. A value of
/// `0` is the "do not store" sentinel.
///
/// The setting is persisted in `FlutterSecureStorage` (Keychain on
/// iOS / EncryptedSharedPreferences on Android) and wiped on identity
/// deletion alongside the rest of the user's local state.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:haven/src/providers/service_providers.dart';

/// Storage key for the sender retention preference (seconds, integer).
const String _retentionStorageKey = 'haven.sender_retention_secs';

/// Sender-side retention preset choices, in seconds.
///
/// `0` is the "do not store" sentinel (Never).
const List<int> kSenderRetentionPresets = <int>[
  0, // Never
  3600, // 1 hour
  6 * 3600, // 6 hours
  24 * 3600, // 24 hours (default)
  3 * 24 * 3600, // 3 days
  7 * 24 * 3600, // 7 days
  30 * 24 * 3600, // 30 days
];

/// Notifier for the sender retention preference.
///
/// Loads the persisted value on construction (defaulting to the Rust
/// core's `defaultSenderRetentionSecs` if unset) and exposes a setter
/// that writes through to secure storage.
class SenderRetentionNotifier extends StateNotifier<int> {
  /// Creates a [SenderRetentionNotifier] with the given default.
  SenderRetentionNotifier({
    required int defaultRetentionSecs,
    FlutterSecureStorage? storage,
  }) : _defaultRetentionSecs = defaultRetentionSecs,
       _storage =
           storage ??
           const FlutterSecureStorage(
             // Android: flutter_secure_storage v10+ stores values using
             // EncryptedSharedPreferences-equivalent ciphers by default, so
             // the legacy `encryptedSharedPreferences: true` flag is no
             // longer required (and is now deprecated). Data is encrypted
             // at rest transparently. iOS options below pin Keychain
             // accessibility to `first_unlock_this_device`, matching the
             // identity service's posture so the retention preference is
             // not available before the device is first unlocked after boot
             // and never syncs to iCloud.
             iOptions: IOSOptions(
               accessibility: KeychainAccessibility.first_unlock_this_device,
             ),
           ),
       super(defaultRetentionSecs) {
    _load();
  }

  final int _defaultRetentionSecs;
  final FlutterSecureStorage _storage;

  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: _retentionStorageKey);
      if (raw == null) return;
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed < 0) return;
      state = parsed;
    } on Object catch (e) {
      debugPrint('[SenderRetention] load failed: $e');
    }
  }

  /// Sets the retention preference and writes it to secure storage.
  Future<void> setRetention(int secs) async {
    if (secs < 0) return;
    state = secs;
    try {
      await _storage.write(key: _retentionStorageKey, value: secs.toString());
    } on Object catch (e) {
      debugPrint('[SenderRetention] write failed: $e');
    }
  }

  /// Resets to the Rust-core default and clears the persisted value.
  Future<void> resetToDefault() async {
    state = _defaultRetentionSecs;
    try {
      await _storage.delete(key: _retentionStorageKey);
    } on Object catch (e) {
      debugPrint('[SenderRetention] reset failed: $e');
    }
  }
}

/// Provider exposing the sender retention preference (seconds).
///
/// The default is sourced from the Rust core's `defaultSenderRetentionSecs`
/// so a single source of truth lives in `haven-core`.
final senderRetentionProvider =
    StateNotifierProvider<SenderRetentionNotifier, int>((ref) {
      final circleService = ref.read(circleServiceProvider);
      return SenderRetentionNotifier(
        defaultRetentionSecs: circleService.defaultSenderRetentionSecs,
      );
    });
