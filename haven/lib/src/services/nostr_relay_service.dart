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

/// Production implementation of [RelayService].
///
/// Uses the Rust core for Tor-routed relay connections.
class NostrRelayService implements RelayService {
  /// Creates a new [NostrRelayService].
  ///
  /// The service must be initialized with [initialize] before use.
  NostrRelayService();

  RelayManagerFfi? _manager;
  bool _initialized = false;
  bool _initializing = false;

  /// Initializes the relay manager with Tor.
  ///
  /// Must be called before any other methods.
  /// Starts Tor bootstrap in the background.
  Future<void> initialize() async {
    if (_initialized) return;
    if (_initializing) {
      // Wait for in-progress initialization
      while (_initializing && !_initialized) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return;
    }

    _initializing = true;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final dataDir = '${appDir.path}/haven';
      _manager = await RelayManagerFfi.newInstance(dataDir: dataDir);
      _initialized = true;
    } finally {
      _initializing = false;
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
    return RelayRejection(
      relay: ffiRejection.url,
      reason: ffiRejection.reason,
    );
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
    await _ensureInitialized();

    // TODO(haven): Implement kind 10051 event fetching once FFI exposes
    // fetch methods. The Rust core needs to expose a fetchEvent or
    // fetchFilter method.

    throw const RelayServiceException(
      'fetchKeyPackageRelays not yet implemented: '
      'requires FFI fetch method',
    );
  }

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) async {
    await _ensureInitialized();

    // TODO(haven): Implement kind 443 event fetching once FFI exposes
    // fetch methods. Flow:
    // 1. Fetch kind 10051 to get user's KeyPackage relay list
    // 2. Fetch kind 443 from those relays
    // 3. Return the most recent valid KeyPackage

    throw const RelayServiceException(
      'fetchKeyPackage not yet implemented: '
      'requires FFI fetch method',
    );
  }

  @override
  Future<PublishResult> publishWelcome({
    required WelcomeEvent welcomeEvent,
    required String senderPubkey,
  }) async {
    await _ensureInitialized();

    // TODO(haven): Implement NIP-59 gift-wrapping of welcome events.
    // The welcome event (kind 444) must remain unsigned per Marmot protocol
    // and be gift-wrapped before publishing.
    //
    // Flow:
    // 1. Create gift-wrap (NIP-59) around the unsigned welcome event
    // 2. Sign the outer gift-wrap event with sender's key
    // 3. Publish to recipient's relays

    throw const RelayServiceException(
      'publishWelcome not yet implemented: '
      'requires NIP-59 gift-wrapping in FFI',
    );
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
        nostrGroupId:
            nostrGroupId != null ? Uint8List.fromList(nostrGroupId) : null,
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
