/// Provider for the user's location precision preference.
///
/// Controls how precisely GPS coordinates are obfuscated before MLS
/// encryption. The setting maps to the Rust `LocationPrecision` enum
/// via [`PrivacyLevelFfi.ffiLabel`] and is threaded through the
/// encrypt-publish pipeline in [locationPublisherProvider].
///
/// Persisted in `FlutterSecureStorage` so the preference survives app
/// restarts.  Wiped on identity deletion alongside other per-account
/// state.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:haven/src/widgets/security/privacy_chip.dart';

/// Storage key for the location precision preference.
const String _precisionStorageKey = 'haven.location_precision';

/// Default precision level — privacy-first.
const PrivacyLevel _defaultPrecision = PrivacyLevel.neighborhood;

/// Notifier for the location precision preference.
///
/// Loads the persisted value on construction (defaulting to
/// [PrivacyLevel.neighborhood] if unset) and exposes a setter that
/// writes through to secure storage.
class LocationPrecisionNotifier extends StateNotifier<PrivacyLevel> {
  /// Creates a [LocationPrecisionNotifier].
  LocationPrecisionNotifier({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          ),
      super(_defaultPrecision) {
    _load();
  }

  final FlutterSecureStorage _storage;

  Future<void> _load() async {
    try {
      final raw = await _storage.read(key: _precisionStorageKey);
      if (raw == null) return;
      final parsed = _parseLevel(raw);
      if (parsed == null) return;
      state = parsed;
    } on Object catch (e) {
      debugPrint('[LocationPrecision] load failed: ${e.runtimeType}');
    }
  }

  /// Sets the precision preference and writes it to secure storage.
  Future<void> setPrecision(PrivacyLevel level) async {
    state = level;
    try {
      await _storage.write(key: _precisionStorageKey, value: level.name);
    } on Object catch (e) {
      debugPrint('[LocationPrecision] write failed: ${e.runtimeType}');
    }
  }

  /// Resets to the default and clears the persisted value.
  Future<void> resetToDefault() async {
    state = _defaultPrecision;
    try {
      await _storage.delete(key: _precisionStorageKey);
    } on Object catch (e) {
      debugPrint('[LocationPrecision] reset failed: ${e.runtimeType}');
    }
  }

  /// Parses a [PrivacyLevel] from its [Enum.name] string.
  static PrivacyLevel? _parseLevel(String value) {
    for (final level in PrivacyLevel.values) {
      if (level.name == value) return level;
    }
    return null;
  }
}

/// Provider exposing the user's location precision preference.
final locationPrecisionProvider =
    StateNotifierProvider<LocationPrecisionNotifier, PrivacyLevel>((ref) {
      return LocationPrecisionNotifier();
    });
