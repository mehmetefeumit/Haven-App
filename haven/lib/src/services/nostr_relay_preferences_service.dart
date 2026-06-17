/// Production [`RelayPreferencesService`] backed by the Rust FFI.
///
/// Delegates to `CircleManagerFfi`'s relay-preference methods. All
/// errors are caught at the FFI boundary, logged via `debugPrint` with
/// only the runtime type (no message contents), and rethrown as typed
/// Dart exceptions whose `message` is safe to display to the user.
library;

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/relay_preferences_service.dart';

/// Production implementation backed by `CircleManagerFfi`.
class NostrRelayPreferencesService implements RelayPreferencesService {
  /// Creates a service backed by a pre-built [CircleManagerFfi].
  ///
  /// The manager MUST already be initialized (i.e.
  /// `CircleManagerFfi.newInstance` has completed). Sharing a single
  /// manager handle across the foreground app and the background isolate
  /// is intentional — see notes on `NostrCircleService.withInjectedManager`.
  const NostrRelayPreferencesService({required CircleManagerFfi manager})
    : _manager = manager;

  final CircleManagerFfi _manager;

  @override
  Future<List<String>> listRelays(RelayCategory category) async {
    try {
      return await _manager.listUserRelays(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('listRelays(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to load relay list.');
    }
  }

  @override
  Future<void> addRelay(RelayCategory category, String url) async {
    try {
      await _manager.addUserRelay(url: url, relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('addRelay(${category.name}) failed: ${e.runtimeType}');
      throw _mapStorageError(e);
    }
  }

  @override
  Future<bool> removeRelay(RelayCategory category, String url) async {
    try {
      return await _manager.removeUserRelay(
        url: url,
        relayType: _toFfi(category),
      );
    } on Object catch (e) {
      debugPrint('removeRelay(${category.name}) failed: ${e.runtimeType}');
      throw _mapStorageError(e);
    }
  }

  @override
  Future<void> restoreDefaults(RelayCategory category) async {
    try {
      await _manager.restoreDefaultsFor(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('restoreDefaults(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to restore defaults.');
    }
  }

  @override
  Future<void> wipeAndResetDefaults(RelayCategory category) async {
    try {
      await _manager.wipeAndResetDefaultsFor(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('wipeAndReset(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to reset defaults.');
    }
  }

  @override
  Future<void> seedDefaultsIfUnseeded() async {
    try {
      await _manager.seedRelayDefaultsIfUnseeded();
    } on Object catch (e) {
      debugPrint('seedDefaults failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to seed default relays.');
    }
  }

  @override
  Future<bool> getPublishRelayList(RelayCategory category) async {
    try {
      return await _manager.getPublishRelayList(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('getPublish(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to read publish setting.');
    }
  }

  @override
  Future<void> setPublishRelayList(
    RelayCategory category, {
    required bool value,
  }) async {
    try {
      await _manager.setPublishRelayList(
        relayType: _toFfi(category),
        value: value,
      );
    } on Object catch (e) {
      debugPrint('setPublish(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException(
        'Failed to update publish setting.',
      );
    }
  }

  @override
  Future<List<String>> publishTargets(RelayCategory category) async {
    try {
      return await _manager.relayPublishTargets(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('publishTargets(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to resolve targets.');
    }
  }

  @override
  Future<BuiltRelayListPublish> buildRelayListPublish({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  }) async {
    try {
      final ffi = await _manager.buildRelayListPublish(
        identitySecretBytes: identitySecretBytes,
        relayType: _toFfi(category),
      );
      return BuiltRelayListPublish(
        suppressed: ffi.suppressed,
        eventJson: ffi.eventJson,
        eventIdHex: ffi.eventIdHex,
        targets: ffi.targets,
        kind: ffi.kind,
        createdAtSecs: ffi.createdAtSecs?.toInt(),
      );
    } on Object catch (e) {
      debugPrint(
        'buildRelayListPublish(${category.name}) failed: ${e.runtimeType}',
      );
      throw const RelayPreferencesException('Failed to build publish request.');
    }
  }

  @override
  Future<void> recordPublishedRelayList({
    required String identityPubkeyHex,
    required int kind,
    required String eventIdHex,
    required int publishedAtSecs,
  }) async {
    try {
      await _manager.recordPublishedRelayList(
        identityPubkeyHex: identityPubkeyHex,
        kind: kind,
        eventIdHex: eventIdHex,
        publishedAtSecs: publishedAtSecs,
      );
    } on Object catch (e) {
      debugPrint('recordPublished failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to record publication.');
    }
  }

  @override
  Future<BuiltUnpublish> buildUnpublishRelayList({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
  }) async {
    try {
      final ffi = await _manager.buildUnpublishRelayList(
        identitySecretBytes: identitySecretBytes,
        relayType: _toFfi(category),
      );
      return BuiltUnpublish(
        suppressed: ffi.suppressed,
        replacementEventJson: ffi.replacementEventJson,
        deletionEventJson: ffi.deletionEventJson,
        targets: ffi.targets,
      );
    } on Object catch (e) {
      debugPrint('buildUnpublish(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException(
        'Failed to build unpublish request.',
      );
    }
  }

  @override
  Future<BuiltUnpublish> buildRelayRemovalScrub({
    required Uint8List identitySecretBytes,
    required RelayCategory category,
    required List<String> droppedRelays,
  }) async {
    try {
      final ffi = await _manager.buildRelayRemovalScrub(
        identitySecretBytes: identitySecretBytes,
        relayType: _toFfi(category),
        droppedRelays: droppedRelays,
      );
      return BuiltUnpublish(
        suppressed: ffi.suppressed,
        replacementEventJson: ffi.replacementEventJson,
        deletionEventJson: ffi.deletionEventJson,
        targets: ffi.targets,
      );
    } on Object catch (e) {
      debugPrint(
        'buildRelayRemovalScrub(${category.name}) failed: ${e.runtimeType}',
      );
      throw const RelayPreferencesException(
        'Failed to build relay removal scrub.',
      );
    }
  }

  /// Maps an FFI error into the appropriate Dart exception type.
  ///
  /// FFI errors arrive as `String`; we inspect a small set of known
  /// substrings so the caller can distinguish "user typed a bad URL"
  /// from "the database lock failed". Unknown errors fall through to
  /// the generic [`RelayPreferencesException`].
  Exception _mapStorageError(Object e) {
    final raw = e.toString().toLowerCase();
    // Validation messages we explicitly raise from the Rust side. Keep
    // the matched substrings short and language-agnostic.
    if (raw.contains('use wss://')) {
      return const RelayValidationError(
        'Use wss:// so traffic to this relay is encrypted.',
      );
    }
    if (raw.contains('credential')) {
      return const RelayValidationError(
        'Relay URL must not contain credentials.',
      );
    }
    if (raw.contains('invalid relay url') ||
        raw.contains('relay url must not be empty')) {
      return const RelayValidationError(
        'Enter a relay address like wss://relay.example.com.',
      );
    }
    if (raw.contains('at least one relay')) {
      return const RelayValidationError(
        'You need at least one relay so others can reach you.',
      );
    }
    return const RelayPreferencesException('Relay update failed.');
  }

  /// Converts the Dart-side category enum to the FFI enum.
  RelayTypeFfi _toFfi(RelayCategory c) => switch (c) {
    RelayCategory.inbox => RelayTypeFfi.inbox,
    RelayCategory.keyPackage => RelayTypeFfi.keyPackage,
  };
}
