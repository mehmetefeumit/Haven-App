/// Production implementation of [IdentityService] using Rust core.
///
/// This implementation:
/// - Uses haven-core for cryptographic operations (via flutter_rust_bridge)
/// - Persists secret bytes using flutter_secure_storage
/// - Automatically loads identity from storage on first access
///
/// # Security Architecture
///
/// ```text
/// Flutter App
///     │
///     ├── NostrIdentityService (this class)
///     │       │
///     │       ├── flutter_secure_storage (iOS Keychain / Android Keystore)
///     │       │       └── Stores: 32-byte secret key
///     │       │
///     │       └── NostrIdentityManager (Rust via FFI)
///     │               └── In-memory: IdentityKeypair (ZeroizeOnDrop)
///     │
///     └── Sign operations go through Rust (secrets never in Dart memory)
/// ```
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';

/// Storage key for the identity secret bytes.
const String _storageKey = 'haven.nostr.identity';

/// Production implementation of [IdentityService].
///
/// Uses the Rust core for cryptographic operations and flutter_secure_storage
/// for persisting the secret key material.
class NostrIdentityService implements IdentityService {
  /// Creates a new [NostrIdentityService].
  ///
  /// Optionally accepts a [FlutterSecureStorage] instance for testing.
  NostrIdentityService({FlutterSecureStorage? storage})
    : _storage = storage ?? _createSecureStorage();

  final FlutterSecureStorage _storage;
  NostrIdentityManager? _manager;
  bool _initialized = false;

  /// Creates platform-optimized secure storage.
  static FlutterSecureStorage _createSecureStorage() {
    return const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
  }

  /// Ensures the manager is initialized and identity is loaded from storage.
  Future<NostrIdentityManager> _ensureInitialized() async {
    if (_manager != null && _initialized) {
      return _manager!;
    }

    // Create the Rust manager
    _manager = await NostrIdentityManager.newInstance();

    // Try to load existing identity from secure storage
    final storedBytes = await _storage.read(key: _storageKey);
    if (storedBytes != null) {
      try {
        final bytes = base64Decode(storedBytes);
        await _manager!.loadFromBytes(secretBytes: bytes);
      } on Exception catch (e) {
        // If loading fails, the stored data might be corrupted
        // Log but don't throw - let the app handle no identity state
        // ignore: avoid_print
        print('Warning: Failed to load identity from storage: $e');
      }
    }

    _initialized = true;
    return _manager!;
  }

  /// Converts a Rust timestamp to DateTime.
  ///
  /// Handles both int (native) and BigInt (web) via PlatformInt64.
  DateTime _timestampToDateTime(num timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000);
  }

  @override
  Future<bool> hasIdentity() async {
    final manager = await _ensureInitialized();
    return manager.hasIdentity();
  }

  @override
  Future<Identity?> getIdentity() async {
    final manager = await _ensureInitialized();

    try {
      final rustIdentity = manager.getIdentity();
      if (rustIdentity == null) {
        return null;
      }

      return Identity(
        pubkeyHex: rustIdentity.pubkeyHex,
        npub: rustIdentity.npub,
        createdAt: _timestampToDateTime(rustIdentity.createdAt),
      );
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to get identity: $e');
    }
  }

  @override
  Future<Identity> createIdentity() async {
    final manager = await _ensureInitialized();

    try {
      // Create identity in Rust
      final rustIdentity = await manager.createIdentity();

      // Get secret bytes and persist to secure storage
      final secretBytes = await manager.getSecretBytes();
      await _storage.write(key: _storageKey, value: base64Encode(secretBytes));

      return Identity(
        pubkeyHex: rustIdentity.pubkeyHex,
        npub: rustIdentity.npub,
        createdAt: _timestampToDateTime(rustIdentity.createdAt),
      );
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to create identity: $e');
    }
  }

  @override
  Future<Identity> importFromNsec(String nsec) async {
    final manager = await _ensureInitialized();

    try {
      // Import identity in Rust
      final rustIdentity = await manager.importFromNsec(nsec: nsec);

      // Get secret bytes and persist to secure storage
      final secretBytes = await manager.getSecretBytes();
      await _storage.write(key: _storageKey, value: base64Encode(secretBytes));

      return Identity(
        pubkeyHex: rustIdentity.pubkeyHex,
        npub: rustIdentity.npub,
        createdAt: _timestampToDateTime(rustIdentity.createdAt),
      );
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to import identity: $e');
    }
  }

  @override
  Future<String> exportNsec() async {
    final manager = await _ensureInitialized();

    try {
      return manager.exportNsec();
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to export nsec: $e');
    }
  }

  @override
  Future<String> sign(Uint8List messageHash) async {
    if (messageHash.length != 32) {
      throw IdentityServiceException(
        'Message hash must be exactly 32 bytes, got ${messageHash.length}',
      );
    }

    final manager = await _ensureInitialized();

    try {
      return manager.sign(messageHash: messageHash.toList());
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to sign: $e');
    }
  }

  @override
  Future<String> getPubkeyHex() async {
    final manager = await _ensureInitialized();

    try {
      return manager.pubkeyHex();
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to get pubkey: $e');
    }
  }

  @override
  Future<void> deleteIdentity() async {
    final manager = await _ensureInitialized();

    try {
      // Delete from Rust manager
      await manager.deleteIdentity();

      // Delete from secure storage
      await _storage.delete(key: _storageKey);
    } on Exception catch (e) {
      throw IdentityServiceException('Failed to delete identity: $e');
    }
  }

  @override
  Future<void> clearCache() async {
    if (_manager != null) {
      await _manager!.clearCache();
    }
  }
}
