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
import 'package:haven/src/services/fresh_secret.dart';
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
  /// Optionally accepts a [FlutterSecureStorage] instance for testing, a
  /// [wipeTileCache] override so the logout tile-cache wipe can be faked in
  /// tests (it defaults to the real [tileCacheWipe] FFI call), a
  /// [keyringInitializer] override so [deleteIdentity]'s keyring-install step
  /// can be faked in tests (defaults to the real [initKeyringStore] FFI
  /// call), and a [managerFactory] override so the storage-retry contract can
  /// be tested without the Rust bridge.
  NostrIdentityService({
    FlutterSecureStorage? storage,
    Future<void> Function()? wipeTileCache,
    Future<void> Function()? keyringInitializer,
    @visibleForTesting Future<NostrIdentityManager> Function()? managerFactory,
  }) : _storage = storage ?? _createSecureStorage(),
       _wipeTileCache = wipeTileCache ?? tileCacheWipe,
       _keyringInitializer = keyringInitializer ?? initKeyringStore,
       _managerFactory = managerFactory ?? NostrIdentityManager.newInstance;

  final FlutterSecureStorage _storage;

  /// Wipes the encrypted map-tile cache. Injectable for testing; defaults to
  /// the [tileCacheWipe] FFI function.
  final Future<void> Function() _wipeTileCache;

  /// Installs the platform keyring backend. Injectable for testing; defaults
  /// to the real [initKeyringStore] FFI function. [deleteIdentity] calls this
  /// itself before [_wipeTileCache] rather than relying on a caller to have
  /// installed the backend first — see the comment there for why that
  /// self-containment matters.
  final Future<void> Function() _keyringInitializer;

  /// Builds the Rust identity manager. Injectable so [_ensureInitialized]'s
  /// retry contract is unit-testable without the FFI bridge; defaults to the
  /// real [NostrIdentityManager.newInstance].
  final Future<NostrIdentityManager> Function() _managerFactory;

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
  ///
  /// **Only a load that actually produced an identity latches.**
  /// [_initialized] short-circuits every later call, so latching a load that
  /// yielded nothing would strand the whole process in a logged-out state:
  /// `MapShell` would never start the receive plane (no live-sync engine, no
  /// KeyPackage publish), and nothing would re-read storage until the app
  /// restarted.
  ///
  /// A secure-storage read is not reliably definitive. An iOS Keychain entry
  /// written with `first_unlock_this_device` can read back `null` while
  /// protected data is momentarily unavailable — before first unlock, on a
  /// cold boot, or when several `FlutterSecureStorage` instances race (the
  /// observed iOS CI failure: the identity was present, one read returned
  /// null, and the session never recovered). Treating that as "no identity,
  /// forever" is the bug; retrying costs one extra read per call while
  /// genuinely logged out, and the flag latches the moment a key is resident.
  Future<NostrIdentityManager> _ensureInitialized() async {
    final cached = _manager;
    if (cached != null && _initialized) {
      return cached;
    }

    // Reuse the manager across retries — it owns the in-memory
    // (`ZeroizeOnDrop`) keypair, so rebuilding it per attempt would churn Rust
    // state and could drop an identity a previous attempt already loaded.
    final manager = _manager ??= await _managerFactory();

    try {
      final storedBytes = await _storage.read(key: _storageKey);
      if (storedBytes != null) {
        await manager.loadFromBytes(secretBytes: base64Decode(storedBytes));
      }
    } on Object catch (e) {
      // Security Rule 6/8: runtimeType only — never let key material or
      // internal state reach a log. Leaving `_initialized` false is the point:
      // a corrupt-or-unreadable read must be retried, not cached.
      debugPrint(
        'Warning: identity load failed (${e.runtimeType}); '
        'retrying on next access',
      );
      return manager;
    }

    _initialized = manager.hasIdentity();
    return manager;
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

      // Persist secret bytes to secure storage. `withFreshSecret` owns the raw
      // 32-byte buffer and scrubs THAT the instant the write settles, so it
      // never outlives the call (Security Rule 9). It does NOT scrub the
      // base64 `String`: `flutter_secure_storage.write` takes only a `String`,
      // and Dart strings are immutable with no overwrite API, so that copy
      // survives until the GC reclaims it. Encoding inside the callback keeps
      // the raw buffer's life short; the String is an irreducible residual of
      // the plugin's String-only API, not something this code can wipe.
      await withFreshSecret(
        manager.getSecretBytes,
        (secret) =>
            _storage.write(key: _storageKey, value: base64Encode(secret)),
      );
      // A key is now resident: latch so `_ensureInitialized` stops re-reading
      // storage on every access (it deliberately does not latch a load that
      // produced nothing — see its doc).
      _initialized = true;

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

      // Persist secret bytes to secure storage — see `createIdentity` for what
      // `withFreshSecret` scrubs here, and for the base64 `String` that no
      // amount of scrubbing can reach.
      await withFreshSecret(
        manager.getSecretBytes,
        (secret) =>
            _storage.write(key: _storageKey, value: base64Encode(secret)),
      );
      // A key is now resident — see `createIdentity` for why this latches.
      _initialized = true;

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
      // Awaited INSIDE the try (Security Rule 8): returning the future
      // un-awaited would hand a rejecting FFI future straight to the caller,
      // and the redaction below would never run — the raw Rust error string
      // reaches the UI instead of a generic message.
      return await manager.exportNsec();
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
      return await manager.sign(messageHash: messageHash.toList());
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
      return await manager.getSecretBytes();
    } on Exception catch (_) {
      debugPrint('[Identity] Secret bytes retrieval failed');
      throw const IdentityServiceException('Failed to get secret bytes');
    }
  }

  /// SharedPreferences key holding the display name for [pubkeyHex].
  ///
  /// Centralised because it is built in three places; a drifting literal here
  /// would silently orphan the value on delete.
  static String _displayNameKey(String pubkeyHex) =>
      'haven.display_name.$pubkeyHex';

  @override
  Future<void> deleteIdentity() async {
    final manager = await _ensureInitialized();

    // Read the pubkey BEFORE the identity is destroyed: the display-name
    // preference is keyed by it, and once the manager is wiped there is no way
    // left to derive the key to remove.
    String? pubkeyHex;
    try {
      pubkeyHex = manager.pubkeyHex();
    } on Object catch (e) {
      debugPrint('[Identity] pubkey read before delete failed: ${e.runtimeType}');
    }

    try {
      // Delete from Rust manager
      await manager.deleteIdentity();

      // Delete from secure storage
      await _storage.delete(key: _storageKey);

      // The display name lives in plain SharedPreferences — app-private, but
      // NOT encrypted, and not covered by the SQLCipher wipe. Left behind it
      // outlives "delete identity" as a plaintext record of who the user was,
      // alongside their pubkey in the key itself. Best-effort and isolated so
      // a preferences failure can neither block nor fail the deletion.
      if (pubkeyHex != null) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_displayNameKey(pubkeyHex));
        } on Object catch (e) {
          debugPrint('[Identity] display-name purge failed: ${e.runtimeType}');
        }
      }

      // Ensure the keyring backend is installed before the tile-cache wipe:
      // the wipe below removes the tiles.db keyring entry, and a MISSING
      // store makes that removal a silent no-op that still reports success —
      // the same shape as the legacy-MLS-cutover defect (a destroy FFI called
      // with no backend installed, so the done-marker latched while the
      // SQLCipher key it was supposed to remove survived). Today's only
      // caller (`IdentityNotifier.deleteIdentity`) happens to install the
      // backend first via the MLS wipe calls that precede this one, but that
      // made correctness a property of caller ORDER, not of this method.
      // `initKeyringStore` is idempotent (cached after first success), so
      // calling it again here is free when a caller already did.
      try {
        await _keyringInitializer();
      } on Object catch (e) {
        debugPrint(
          '[Identity] keyring init before tile cache wipe failed: '
          '${e.runtimeType}',
        );
      }
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
    return prefs.getString(_displayNameKey(identity.pubkeyHex));
  }

  @override
  Future<void> setDisplayName(String? name) async {
    final identity = await getIdentity();
    if (identity == null) return;
    final prefs = await SharedPreferences.getInstance();
    final key = _displayNameKey(identity.pubkeyHex);
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
