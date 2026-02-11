/// Production implementation of [RelayService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for Tor-routed relay connections (via flutter_rust_bridge)
/// - All connections are routed through embedded Tor client
/// - Provides circuit isolation per group for privacy
///
/// # Architecture
///
/// ```text
/// Flutter App
///     │
///     └── NostrRelayService (this class)
///             │
///             └── RelayManagerFfi (Rust via FFI)
///                     │
///                     ├── Embedded Tor Client
///                     └── Nostr Relay Pool
/// ```
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:path_provider/path_provider.dart';

/// Abstraction for getting the data directory path.
///
/// This allows for dependency injection in tests.
abstract class DataDirectoryProvider {
  /// Gets the application documents directory path.
  Future<String> getDataDirectory();
}

/// Production implementation that uses path_provider.
class PathProviderDataDirectory implements DataDirectoryProvider {
  /// Creates a new [PathProviderDataDirectory].
  const PathProviderDataDirectory();

  @override
  Future<String> getDataDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/haven';
  }
}

/// Production implementation of [RelayService].
///
/// Uses the Rust core for Tor-routed relay connections.
class NostrRelayService implements RelayService {
  /// Creates a new [NostrRelayService].
  ///
  /// The service must be initialized with [initialize] before use.
  /// Optionally accepts a [DataDirectoryProvider] for testing.
  NostrRelayService({DataDirectoryProvider? dataDirectoryProvider})
    : _dataDirectoryProvider =
          dataDirectoryProvider ?? const PathProviderDataDirectory();

  final DataDirectoryProvider _dataDirectoryProvider;
  RelayManagerFfi? _manager;
  bool _initialized = false;
  Completer<void>? _initCompleter;

  /// Initializes the relay manager with Tor.
  ///
  /// Must be called before any other methods.
  /// Starts Tor bootstrap in the background.
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
      final dataDir = await _dataDirectoryProvider.getDataDirectory();
      _manager = await RelayManagerFfi.newInstance(dataDir: dataDir);
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

  /// Converts FFI TorStatus to service TorStatus.
  TorStatus _convertTorStatus(TorStatusFfi ffiStatus) {
    return TorStatus(
      progress: ffiStatus.progress,
      isReady: ffiStatus.isReady,
      phase: ffiStatus.phase,
    );
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
    } on Exception catch (e) {
      throw RelayServiceException('Failed to fetch KeyPackage relays: $e');
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
      );
    } on Exception catch (e) {
      throw RelayServiceException('Failed to fetch KeyPackage: $e');
    }
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    final manager = await _ensureInitialized();

    try {
      // The welcome event is already gift-wrapped (kind 1059).
      // Simply publish it to the recipient's relays.
      // Use identity circuit since this is an invitation operation.
      final ffiResult = await manager.publishEvent(
        eventJson: welcomeEvent.eventJson,
        relays: welcomeEvent.recipientRelays,
        isIdentityOperation: true,
      );

      return _convertPublishResult(ffiResult);
    } on Exception catch (e) {
      throw RelayServiceException('Failed to publish welcome event: $e');
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
    } on Exception catch (e) {
      throw RelayServiceException('Failed to fetch gift wraps: $e');
    }
  }

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
    required bool isIdentityOperation,
    List<int>? nostrGroupId,
  }) async {
    final manager = await _ensureInitialized();

    try {
      final ffiResult = await manager.publishEvent(
        eventJson: eventJson,
        relays: relays,
        isIdentityOperation: isIdentityOperation,
        nostrGroupId: nostrGroupId != null
            ? Uint8List.fromList(nostrGroupId)
            : null,
      );

      return _convertPublishResult(ffiResult);
    } on Exception catch (e) {
      throw RelayServiceException('Failed to publish event: $e');
    }
  }

  @override
  Future<TorStatus> getTorStatus() async {
    final manager = await _ensureInitialized();

    try {
      final ffiStatus = await manager.torStatus();
      return _convertTorStatus(ffiStatus);
    } on Exception catch (e) {
      throw RelayServiceException('Failed to get Tor status: $e');
    }
  }

  @override
  Future<bool> isReady() async {
    final manager = await _ensureInitialized();

    try {
      return manager.isReady();
    } on Exception catch (e) {
      throw RelayServiceException('Failed to check ready status: $e');
    }
  }

  @override
  Future<void> waitForReady() async {
    final manager = await _ensureInitialized();

    try {
      // Poll until Tor is ready
      const maxAttempts = 120; // 2 minutes with 1-second intervals
      const pollInterval = Duration(seconds: 1);

      for (var i = 0; i < maxAttempts; i++) {
        if (await manager.isReady()) {
          return;
        }
        await Future<void>.delayed(pollInterval);
      }

      throw const RelayServiceException('Tor bootstrap timed out');
    } on RelayServiceException {
      rethrow;
    } on Exception catch (e) {
      throw RelayServiceException('Failed to wait for Tor: $e');
    }
  }

  /// Shuts down the relay manager and Tor.
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
}
