/// Production implementation of [RelayService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for relay connections (via flutter_rust_bridge)
/// - Direct WSS connections to Nostr relays
///
/// # Architecture
///
/// ```text
/// Flutter App
///     |
///     +-- NostrRelayService (this class)
///             |
///             +-- RelayManagerFfi (Rust via FFI)
///                     |
///                     +-- Nostr Relay Pool (WSS)
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';

// Re-exported for backward compatibility: `DataDirectoryProvider` +
// `PathProviderDataDirectory` moved to `data_directory_provider.dart` (the
// single-source-of-truth resolver, M7-6). Existing importers of this file
// keep resolving them.
export 'package:haven/src/services/data_directory_provider.dart'
    show DataDirectoryProvider, PathProviderDataDirectory;

/// Production implementation of [RelayService].
///
/// Uses the Rust core for direct WSS relay connections.
class NostrRelayService implements RelayService {
  /// Creates a new [NostrRelayService].
  ///
  /// The service must be initialized with [initialize] before use.
  NostrRelayService();

  RelayManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Initializes the relay manager.
  ///
  /// Must be called before any other methods.
  /// Thread-safe: concurrent calls will wait for the first initialization.
  Future<void> initialize() async {
    if (_initialized) return;

    // If initialization is in progress, wait for it
    if (_initCompleter != null) {
      await _initCompleter!.future;
      return;
    }

    // Start initialization
    _initCompleter = Completer<void>();
    try {
      _manager = await RelayManagerFfi.newInstance();
      _initialized = true;
      _initCompleter!.complete();
      _initCompleter = null;
    } on Object catch (e, stackTrace) {
      _initCompleter!.completeError(e, stackTrace);
      _initCompleter = null;
      rethrow;
    }
  }

  /// Ensures the manager is initialized.
  Future<RelayManagerFfi> _ensureInitialized() async {
    if (!_initialized || _manager == null) {
      await initialize();
    }
    return _manager!;
  }

  /// Converts FFI RelayRejection to service RelayRejection.
  RelayRejection _convertRejection(RelayRejectionFfi ffiRejection) {
    return RelayRejection(relay: ffiRejection.url, reason: ffiRejection.reason);
  }

  /// Converts FFI PublishResult to service PublishResult.
  PublishResult _convertPublishResult(PublishResultFfi ffiResult) {
    return PublishResult(
      eventId: ffiResult.eventId,
      acceptedBy: ffiResult.acceptedBy,
      rejectedBy: ffiResult.rejectedBy.map(_convertRejection).toList(),
      failed: ffiResult.failed,
    );
  }

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      return await manager.fetchKeypackageRelays(pubkey: pubkey);
    } on Object catch (e) {
      debugPrint('Failed to fetch KeyPackage relays: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch KeyPackage relays');
    }
  }

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      return await manager.fetchNip65Relays(pubkey: pubkey);
    } on Object catch (e) {
      debugPrint('Failed to fetch NIP-65 relays: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch NIP-65 relays');
    }
  }

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    final manager = await _ensureInitialized();

    try {
      // Use the convenience method that fetches both key package and relays
      final result = await manager.fetchMemberKeypackage(pubkey: pubkey);

      if (result == null) {
        return null;
      }

      return KeyPackageData(
        pubkey: pubkey,
        eventJson: result.keyPackageJson,
        relays: result.inboxRelays,
        nip65Relays: result.nip65Relays,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch KeyPackage: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch KeyPackage');
    }
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.publishEvent(
        eventJson: welcomeEvent.eventJson,
        relays: welcomeEvent.recipientRelays,
      );

      return _convertPublishResult(ffiResult);
    } on Object catch (e) {
      debugPrint('Failed to publish welcome event: ${e.runtimeType}');
      throw const RelayServiceException('Failed to publish welcome event');
    }
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      manager.publishEventFireAndForget(eventJson: eventJson, relays: relays);
    } on Object catch (e) {
      debugPrint('Failed to publish fire-and-forget event: ${e.runtimeType}');
      throw const RelayServiceException(
        'Failed to publish fire-and-forget event',
      );
    }
  }

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      return await manager.fetchGiftWraps(
        recipientPubkey: recipientPubkey,
        relays: relays,
        since: sinceTimestamp,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch gift wraps: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch gift wraps');
    }
  }

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      final ffiResults = await manager.fetchGiftWrapsPerRelay(
        recipientPubkey: recipientPubkey,
        relays: relays,
        since: sinceTimestamp,
      );

      return ffiResults
          .map(
            (r) => RelayGiftWrapFetch(
              relayUrl: r.relayUrl,
              responded: r.responded,
              events: r.events,
            ),
          )
          .toList();
    } on Object catch (e) {
      debugPrint('Failed to fetch gift wraps per relay: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch gift wraps per relay');
    }
  }

  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async {
    // Best-effort: a background/resume sweep must never throw into its caller.
    try {
      final manager = await _ensureInitialized();
      final r = await manager.runCatchupAllCircles(
        circle: circle,
        ownPubkeyHex: ownPubkeyHex,
        maxDurationSecs: BigInt.from(maxDurationSecs),
      );
      return CatchupResult(
        circlesSwept: r.circlesSwept,
        locationsApplied: r.locationsApplied,
        commitsApplied: r.commitsApplied,
        autoCommitsStaged: r.autoCommitsStaged,
        cursorsAdvanced: r.cursorsAdvanced,
        deadlineHit: r.deadlineHit,
        relayErrors: r.relayErrors,
      );
    } on Object catch (e) {
      debugPrint('[Catchup] sweep failed: ${e.runtimeType}');
      return const CatchupResult.empty();
    }
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.publishEvent(
        eventJson: eventJson,
        relays: relays,
      );

      return _convertPublishResult(ffiResult);
    } on Object catch (e) {
      debugPrint('Failed to publish event: ${e.runtimeType}');
      throw const RelayServiceException('Failed to publish event');
    }
  }

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final sinceTimestamp = since != null
          ? since.millisecondsSinceEpoch ~/ 1000
          : null;

      return await manager.fetchGroupMessages(
        nostrGroupId: Uint8List.fromList(nostrGroupId),
        relays: relays,
        since: sinceTimestamp,
        limit: limit,
      );
    } on Object catch (e) {
      debugPrint('Failed to fetch group messages: ${e.runtimeType}');
      throw const RelayServiceException('Failed to fetch group messages');
    }
  }

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.checkEventOnRelay(
        relayUrl: relayUrl,
        authorPubkey: authorPubkey,
        eventKind: eventKind,
      );

      return RelayEventCheck(
        relayUrl: ffiResult.relayUrl,
        found: ffiResult.found,
        eventCount: ffiResult.eventCount,
        newestTimestamp: ffiResult.newestTimestamp != null
            ? DateTime.fromMillisecondsSinceEpoch(
                ffiResult.newestTimestamp! * 1000,
              )
            : null,
      );
    } on Object catch (e) {
      debugPrint('Failed to check event on relay: ${e.runtimeType}');
      throw const RelayServiceException('Failed to check event on relay');
    }
  }

  /// Shuts down the relay manager.
  ///
  /// Call this when the app is being closed or going to background.
  Future<void> shutdown() async {
    if (_manager != null) {
      try {
        await _manager!.shutdown();
      } on Exception {
        // Ignore shutdown errors
      }
      _manager = null;
      _initialized = false;
    }
  }

  @override
  Future<void> disconnectRelay(String url) async {
    try {
      final manager = await _ensureInitialized();
      await manager.disconnectRelay(url: url);
    } on Object catch (e) {
      // Best-effort. The relay won't be referenced by storage after this
      // point, so even if the disconnect fails, no further publishes /
      // fetches will target it.
      debugPrint('disconnectRelay failed: ${e.runtimeType}');
    }
  }
}
