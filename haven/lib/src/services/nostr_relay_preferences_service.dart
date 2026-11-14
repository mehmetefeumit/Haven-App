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
  /// Creates a service that asks [circleManagerFactory] for the manager at
  /// every call.
  ///
  /// Never hold the handle: the circle service disposes it at every Android
  /// background handoff and opens a new one on resume, and every call on the
  /// disposed one fails.
  const NostrRelayPreferencesService({
    required Future<CircleManagerFfi> Function() circleManagerFactory,
  }) : _circleManager = circleManagerFactory;

  final Future<CircleManagerFfi> Function() _circleManager;

  @override
  Future<List<String>> listRelays(RelayCategory category) async {
    try {
      final manager = await _circleManager();
      return await manager.listUserRelays(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('listRelays(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to load relay list.');
    }
  }

  @override
  Future<void> addRelay(RelayCategory category, String url) async {
    try {
      final manager = await _circleManager();
      await manager.addUserRelay(url: url, relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('addRelay(${category.name}) failed: ${e.runtimeType}');
      throw _mapStorageError(e);
    }
  }

  @override
  Future<bool> removeRelay(RelayCategory category, String url) async {
    try {
      final manager = await _circleManager();
      return await manager.removeUserRelay(
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
      final manager = await _circleManager();
      await manager.restoreDefaultsFor(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('restoreDefaults(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to restore defaults.');
    }
  }

  @override
  Future<void> wipeAndResetDefaults(RelayCategory category) async {
    try {
      final manager = await _circleManager();
      await manager.wipeAndResetDefaultsFor(relayType: _toFfi(category));
    } on Object catch (e) {
      debugPrint('wipeAndReset(${category.name}) failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to reset defaults.');
    }
  }

  @override
  Future<void> seedDefaultsIfUnseeded() async {
    try {
      final manager = await _circleManager();
      await manager.seedRelayDefaultsIfUnseeded();
    } on Object catch (e) {
      debugPrint('seedDefaults failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to seed default relays.');
    }
  }

  @override
  Future<bool> getPublishRelayList(RelayCategory category) async {
    try {
      final manager = await _circleManager();
      return await manager.getPublishRelayList(relayType: _toFfi(category));
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
      final manager = await _circleManager();
      await manager.setPublishRelayList(
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
      final manager = await _circleManager();
      return await manager.relayPublishTargets(relayType: _toFfi(category));
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
      final manager = await _circleManager();
      final ffi = await manager.buildRelayListPublish(
        identitySecretBytes: identitySecretBytes,
        relayType: _toFfi(category),
      );
      return BuiltRelayListPublish(
        suppressed: ffi.suppressed,
        awaitingResetAcknowledgement: ffi.awaitingResetAcknowledgement,
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
      final manager = await _circleManager();
      await manager.recordPublishedRelayList(
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
      final manager = await _circleManager();
      final ffi = await manager.buildUnpublishRelayList(
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
      final manager = await _circleManager();
      final ffi = await manager.buildRelayRemovalScrub(
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

  @override
  Future<ProfilePoolStatus> profilePoolStatus() async {
    try {
      final manager = await _circleManager();
      final ffi = await manager.profilePoolStatus();
      return ProfilePoolStatus(
        configured: ffi.configured,
        excluded: ffi.excluded,
        usable: ffi.usable,
        isUnderflow: ffi.isUnderflow,
      );
    } on Object catch (e) {
      debugPrint('profilePoolStatus failed: ${e.runtimeType}');
      throw const RelayPreferencesException(
        'Failed to read profile relay status.',
      );
    }
  }

  @override
  Future<void> restoreDefaultProfileRelays() async {
    try {
      final manager = await _circleManager();
      await manager.restoreDefaultProfileRelays();
    } on Object catch (e) {
      debugPrint('restoreDefaultProfileRelays failed: ${e.runtimeType}');
      throw const RelayPreferencesException('Failed to restore defaults.');
    }
  }

  /// The five Haven-authored validation sentences
  /// `CircleError::InvalidRelayInput`'s `Display` renders — see
  /// `haven-core/src/circle/storage_relay_prefs.rs`. Since Phase L0, every
  /// `CircleError` variant's `Display` is payload-free (Security Rule 15),
  /// so these fixed sentences ARE the whole FFI error string, never a
  /// substring of a larger, input-carrying message. `_mapStorageError`
  /// matches on the whole sentence for that reason.
  static const _sentenceUrlEmpty = 'Relay URL must not be empty';
  static const _sentenceUseWss = 'Use wss:// for security';
  static const _sentenceHasCredentials =
      'Relay URL must not contain credentials';
  static const _sentenceInvalidUrl = 'Invalid relay URL';
  static const _sentenceAtLeastOneRequired =
      'At least one relay is required per category';

  /// Maps an FFI error into the appropriate Dart exception type.
  ///
  /// FFI errors arrive as `String`. Since Phase L0 (Security Rule 15) that
  /// string is always one of Haven's own fixed, payload-free sentences (see
  /// the `_sentence*` constants above) or an opaque non-validation failure —
  /// never remote-authored prose or anything carrying the rejected input, so
  /// matching the whole sentence (case-insensitively, since the FFI string's
  /// casing is not itself a promise) is safe and cannot be defeated by user
  /// input. Unknown errors fall through to the generic
  /// [`RelayPreferencesException`].
  Exception _mapStorageError(Object e) {
    final raw = e.toString().toLowerCase();
    if (raw.contains(_sentenceUseWss.toLowerCase())) {
      return const RelayValidationError(
        'Use wss:// so traffic to this relay is encrypted.',
      );
    }
    if (raw.contains(_sentenceHasCredentials.toLowerCase())) {
      return const RelayValidationError(
        'Relay URL must not contain credentials.',
      );
    }
    if (raw.contains(_sentenceUrlEmpty.toLowerCase()) ||
        raw.contains(_sentenceInvalidUrl.toLowerCase())) {
      return const RelayValidationError(
        'Enter a relay address like wss://relay.example.com.',
      );
    }
    if (raw.contains(_sentenceAtLeastOneRequired.toLowerCase())) {
      return const RelayValidationError(
        'You need at least one relay so others can reach you.',
      );
    }
    return const RelayPreferencesException('Relay update failed.');
  }

  /// Converts the Dart-side category enum to the FFI enum.
  ///
  /// `RelayCategory.keyPackage` maps to `RelayTypeFfi.nip65` (Dark Matter
  /// W2): the wire kind changed 10051→10002, but it is persisted under the
  /// SAME `RelayType::KeyPackage` storage slot, so no relay-preference data
  /// migrates and the Dart-side category name is unchanged.
  ///
  /// `RelayCategory.profile` maps to `RelayTypeFfi.profile` — the CRUD
  /// methods above (`listRelays`/`addRelay`/`removeRelay`/`restoreDefaults`/
  /// `wipeAndResetDefaults`) work fine for it: the profile plane is an
  /// ordinary relay category in storage, and this generic path is the ONLY
  /// one (Rust has no dedicated profile CRUD wrappers — duplicates existed,
  /// went unused, and were removed so the two could not drift). The
  /// publish-oriented methods (`getPublishRelayList`, `setPublishRelayList`,
  /// `publishTargets`, `buildRelayListPublish`, `buildUnpublishRelayList`,
  /// `buildRelayRemovalScrub`) throw for it on the Rust side — callers MUST
  /// NOT invoke those with `RelayCategory.profile` (see
  /// `ProfileRelaysNotifier`, which never does).
  RelayTypeFfi _toFfi(RelayCategory c) => switch (c) {
    RelayCategory.inbox => RelayTypeFfi.inbox,
    RelayCategory.keyPackage => RelayTypeFfi.nip65,
    RelayCategory.profile => RelayTypeFfi.profile,
  };
}
