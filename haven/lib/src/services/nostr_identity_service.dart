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

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Storage key for the identity secret bytes.
///
/// The constant is exported under [identityStorageKeyForTesting] so the
/// E2E test harness can pre-seed identities without re-deriving the
/// literal (which would silently drift if production renamed the key).
const String _storageKey = 'haven.nostr.identity';

/// Public alias of the identity storage key, intended for test code.
///
/// Production callers should use the `_storageKey` private constant.
/// Tests that pre-populate the secure storage (E2E scenarios) should
/// import this so a key rename surfaces as a compile error rather than
/// a silently misrouted write.
@visibleForTesting
const String identityStorageKeyForTesting = _storageKey;

/// Production implementation of [IdentityService].
///
/// Uses the Rust core for cryptographic operations and flutter_secure_storage
/// for persisting the secret key material.
class NostrIdentityService implements IdentityService {
  /// Creates a new [NostrIdentityService].
  ///
  /// Optionally accepts a [FlutterSecureStorage] instance for testing, and a
  /// [wipeTileCache] override so the logout tile-cache wipe can be faked in
  /// tests (it defaults to the real [tileCacheWipe] FFI call).
  NostrIdentityService({
    FlutterSecureStorage? storage,
    Future<void> Function()? wipeTileCache,
  }) : _storage = storage ?? _createSecureStorage(),
       _wipeTileCache = wipeTileCache ?? tileCacheWipe;

  final FlutterSecureStorage _storage;

  /// Wipes the encrypted map-tile cache. Injectable for testing; defaults to
  /// the [tileCacheWipe] FFI function.
  final Future<void> Function() _wipeTileCache;
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
      } on Exception catch (_) {
        // If loading fails, the stored data might be corrupted
        // Log but don't throw - let the app handle no identity state
        debugPrint('Warning: Failed to load identity from storage');
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
      debugPrint('Failed to get identity: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to get identity');
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
      debugPrint('Failed to create identity: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to create identity');
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
    } on Exception catch (_) {
      debugPrint('[Identity] Import failed');
      throw const IdentityServiceException('Failed to import identity');
    }
  }

  @override
  Future<String> exportNsec() async {
    final manager = await _ensureInitialized();

    try {
      return manager.exportNsec();
    } on Exception catch (_) {
      debugPrint('[Identity] Export failed');
      throw const IdentityServiceException('Failed to export secret key');
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
      debugPrint('Failed to sign: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to sign');
    }
  }

  @override
  Future<String> getPubkeyHex() async {
    final manager = await _ensureInitialized();

    try {
      return manager.pubkeyHex();
    } on Exception catch (e) {
      debugPrint('Failed to get pubkey: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to get public key');
    }
  }

  @override
  Future<List<int>> getSecretBytes() async {
    final manager = await _ensureInitialized();

    try {
      return manager.getSecretBytes();
    } on Exception catch (_) {
      debugPrint('[Identity] Secret bytes retrieval failed');
      throw const IdentityServiceException('Failed to get secret bytes');
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

      // Wipe the encrypted map-tile cache so a new identity never inherits the
      // prior identity's cached map areas (the cache is a record of everywhere
      // the circle has been). Best-effort and isolated in its own try/catch so a
      // wipe failure can neither block nor fail the identity deletion. The Rust
      // wipe clears content, closes connections, deletes tiles.db + its
      // -wal/-shm/-journal sidecars, and removes the tiles keyring entry.
      try {
        await _wipeTileCache();
      } on Object catch (e) {
        debugPrint('[Identity] tile cache wipe failed: ${e.runtimeType}');
      }
    } on Exception catch (e) {
      debugPrint('Failed to delete identity: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to delete identity');
    }
  }

  @override
  Future<String?> getDisplayName() async {
    final identity = await getIdentity();
    if (identity == null) return null;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('haven.display_name.${identity.pubkeyHex}');
  }

  @override
  Future<void> setDisplayName(String? name) async {
    final identity = await getIdentity();
    if (identity == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = 'haven.display_name.${identity.pubkeyHex}';
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, trimmed);
    }
  }

  @override
  Future<void> clearCache() async {
    if (_manager != null) {
      await _manager!.clearCache();
    }
  }
}
