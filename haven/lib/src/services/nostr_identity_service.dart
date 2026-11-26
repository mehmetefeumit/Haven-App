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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/fresh_secret.dart';
import 'package:haven/src/services/identity_secure_storage.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prefix of the SharedPreferences key holding the user's display name, one
/// key per identity pubkey.
const kDisplayNamePrefPrefix = 'haven.display_name.';

/// Set while the user's own name, dropped by the storage reset's preferences
/// clear, is still to be taken from their published profile. Removed with
/// the display name when the identity is deleted.
const kOwnNameReseedOwedKey = 'haven.storage_reset.own_name_reseed_owed';

/// What one storage read showed about the stored identity key.
enum _StoredKey {
  /// The read returned a key, and it loaded.
  present,

  /// The read returned nothing.
  absent,

  /// The read failed, or what it returned could not be decoded or loaded: a
  /// key may be stored.
  unknown,
}

/// One [NostrIdentityService._ensureInitialized] attempt's result.
typedef _Loaded = ({NostrIdentityManager manager, _StoredKey storedKey});

/// Production implementation of [IdentityService].
///
/// Uses the Rust core for cryptographic operations and flutter_secure_storage
/// for persisting the secret key material.
///
/// Haven never overwrites or deletes the stored key on a failed read: while
/// storage cannot say whether a key is stored, [hasIdentity] throws and
/// [createIdentity] / [importFromNsec] refuse, each with
/// [IdentityStorageUnavailableException], and a new key is written only
/// where `containsKey` finds none.
class NostrIdentityService implements IdentityService {
  /// Creates a new [NostrIdentityService].
  ///
  /// Optionally accepts a [FlutterSecureStorage] instance for testing, a
  /// [wipeTileCache] override so the logout tile-cache wipe can be faked in
  /// tests (it defaults to the real [tileCacheWipe] FFI call), a
  /// [keyringInitializer] override so [deleteIdentity]'s keyring-install step
  /// can be faked in tests (defaults to the real [initKeyringStore] FFI
  /// call), a [managerFactory] override so the storage-retry contract can
  /// be tested without the Rust bridge, and [isIOS] so the Keychain status a
  /// failed read logs can be tested off-device.
  NostrIdentityService({
    FlutterSecureStorage? storage,
    Future<void> Function()? wipeTileCache,
    Future<void> Function()? keyringInitializer,
    @visibleForTesting Future<NostrIdentityManager> Function()? managerFactory,
    @visibleForTesting bool? isIOS,
  }) : _storage = storage ?? identitySecureStorage,
       _wipeTileCache = wipeTileCache ?? tileCacheWipe,
       _keyringInitializer = keyringInitializer ?? initKeyringStore,
       _managerFactory = managerFactory ?? NostrIdentityManager.newInstance,
       _isIOS = isIOS ?? Platform.isIOS;

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

  final bool _isIOS;

  NostrIdentityManager? _manager;
  bool _initialized = false;

  /// Guards [_ensureInitialized] against concurrent callers each starting
  /// their own manager construction / storage read — see that method's doc.
  Completer<_Loaded>? _initCompleter;

  /// Ensures the manager is initialized and identity is loaded from storage,
  /// and answers what this attempt's read showed.
  ///
  /// **Only a load that produced a stored identity latches.**
  /// [_initialized] short-circuits every later call, so latching a load that
  /// yielded nothing would strand the whole process in a logged-out state:
  /// `MapShell` would never start the receive plane (no live-sync engine, no
  /// KeyPackage publish), and nothing would re-read storage until the app
  /// restarted. A key the manager holds that storage did not return (one a
  /// create is still writing) does not latch either.
  ///
  /// A read that produced no identity is not proof that none is stored: the
  /// observed iOS CI failure had the identity present and one read produce
  /// none. The plugin answers `null` for a missing item and for a value that
  /// is not UTF-8, and throws on any other failure — on iOS any Keychain
  /// status but success and not-found, e.g. while protected data is
  /// unavailable. A throw, or a value that does not decode or load, is
  /// [_StoredKey.unknown]: nothing may write a key while it stands.
  ///
  /// **Concurrent callers share one in-flight attempt.** Several UI paths
  /// (the Identity page alone fires 4-6 on open) call this within the same
  /// microtask window; without [_initCompleter] each would race its own
  /// [_managerFactory] call and its own secure-storage read. The first caller
  /// creates the completer and does the work; every caller that arrives while
  /// it is set awaits the same [Completer.future] — and so that attempt's
  /// result — instead of starting a second one. The completer is cleared (in
  /// `finally`) the moment that attempt settles — success, a caught storage
  /// error, or a thrown one — so the no-latch-on-a-miss contract above is
  /// unaffected: the *next*, non-concurrent call still starts a fresh attempt
  /// and re-reads storage.
  Future<_Loaded> _ensureInitialized() async {
    final cached = _manager;
    if (cached != null && _initialized) {
      return (manager: cached, storedKey: _StoredKey.present);
    }

    final inFlight = _initCompleter;
    if (inFlight != null) {
      return inFlight.future;
    }

    final completer = Completer<_Loaded>();
    // When nothing raced this call there is no second awaiter, so the error
    // completion below would reach the zone as an UNHANDLED async error even
    // though `rethrow` already delivers it to the real caller. `ignore()`
    // suppresses only that duplicate report — a concurrent waiter still gets
    // the error from its own `await`. Without it every widget test that lets
    // the real service reach an uninitialised FFI fails AFTER completing.
    completer.future.ignore();
    _initCompleter = completer;
    try {
      // Reuse the manager across retries — it owns the in-memory
      // (`ZeroizeOnDrop`) keypair, so rebuilding it per attempt would churn
      // Rust state and could drop an identity a previous attempt already
      // loaded.
      final manager = _manager ??= await _managerFactory();

      final String? storedBytes;
      try {
        storedBytes = await _storage.read(key: identityStorageKey);
        if (storedBytes != null) {
          final bytes = base64Decode(storedBytes);
          try {
            await manager.loadFromBytes(secretBytes: bytes);
          } finally {
            bytes.fillRange(0, bytes.length, 0);
          }
        }
      } on Object catch (e) {
        // Security Rule 6/8: runtimeType and an iOS OSStatus only — never let
        // key material or internal state reach a log. Leaving `_initialized`
        // false is the point: a corrupt-or-unreadable read must be retried,
        // not cached.
        final keychainStatus = _keychainStatus(e);
        debugPrint(
          'Warning: identity load failed (${e.runtimeType}$keychainStatus); '
          'retrying on next access',
        );
        final loaded = (manager: manager, storedKey: _StoredKey.unknown);
        completer.complete(loaded);
        return loaded;
      }

      _initialized = storedBytes != null && manager.hasIdentity();
      final loaded = (
        manager: manager,
        storedKey: storedBytes == null ? _StoredKey.absent : _StoredKey.present,
      );
      completer.complete(loaded);
      return loaded;
    } on Object catch (e, st) {
      // _managerFactory() itself threw (outside the storage try/catch above):
      // propagate to every waiter, not just this caller.
      completer.completeError(e, st);
      rethrow;
    } finally {
      _initCompleter = null;
    }
  }

  /// The Keychain status of an iOS secure-storage failure, for its log line.
  ///
  /// An OSStatus is a platform error code that tells no user apart. Nothing
  /// else of the exception is logged: its message is free text, and an
  /// Android `details` is a stack trace.
  String _keychainStatus(Object error) {
    if (!_isIOS || error is! PlatformException) return '';
    final status = error.details;
    return status is int ? ', Keychain status $status' : '';
  }

  /// Writes the key [manager] has just created or imported, or takes it out
  /// of memory again: a key that is not stored must not be used, since
  /// everything published under it is lost at the next start.
  ///
  /// Refuses when storage holds a key or cannot say: the read before this
  /// returned nothing, but that is not proof (see [_ensureInitialized]), and
  /// an iOS write over an existing item that fails to update it deletes it.
  Future<void> _storeNewKey(NostrIdentityManager manager) async {
    try {
      final bool occupied;
      try {
        occupied = await _storage.containsKey(key: identityStorageKey);
      } on Object catch (e) {
        final keychainStatus = _keychainStatus(e);
        debugPrint(
          'Warning: identity storage check failed '
          '(${e.runtimeType}$keychainStatus)',
        );
        throw const IdentityStorageUnavailableException();
      }
      if (occupied) throw const IdentityStorageUnavailableException();
      // `withFreshSecret` owns the raw 32-byte buffer and scrubs THAT the
      // instant the write settles, so it never outlives the call (Security
      // Rule 9). It does NOT scrub the base64 `String`:
      // `flutter_secure_storage.write` takes only a `String`, and Dart
      // strings are immutable with no overwrite API, so that copy survives
      // until the GC reclaims it. Encoding inside the callback keeps the raw
      // buffer's life short; the String is an irreducible residual of the
      // plugin's String-only API, not something this code can wipe.
      await withFreshSecret(
        manager.getSecretBytes,
        (secret) => _storage.write(
          key: identityStorageKey,
          value: base64Encode(secret),
        ),
      );
    } on Object {
      _initialized = false;
      try {
        await manager.deleteIdentity();
      } on Object catch (e) {
        // Rust's in-memory delete fails only on a poisoned lock; the unstored
        // key then stays in memory.
        debugPrint('[Identity] unstored key removal failed: ${e.runtimeType}');
      }
      rethrow;
    }
    // A key is now resident and stored: latch so `_ensureInitialized` stops
    // re-reading storage on every access.
    _initialized = true;
  }

  /// Converts a Rust timestamp to DateTime.
  ///
  /// Handles both int (native) and BigInt (web) via PlatformInt64.
  DateTime _timestampToDateTime(num timestamp) {
    return DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000);
  }

  @override
  Future<bool> hasIdentity() async {
    final (:manager, :storedKey) = await _ensureInitialized();
    if (manager.hasIdentity()) return true;
    if (storedKey == _StoredKey.unknown) {
      throw const IdentityStorageUnavailableException();
    }
    return false;
  }

  @override
  Future<Identity?> getIdentity() async {
    final manager = (await _ensureInitialized()).manager;

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
    final (:manager, :storedKey) = await _ensureInitialized();
    if (storedKey == _StoredKey.unknown) {
      throw const IdentityStorageUnavailableException();
    }

    try {
      // Create identity in Rust
      final rustIdentity = await manager.createIdentity();
      await _storeNewKey(manager);

      return Identity(
        pubkeyHex: rustIdentity.pubkeyHex,
        npub: rustIdentity.npub,
        createdAt: _timestampToDateTime(rustIdentity.createdAt),
      );
    } on IdentityStorageUnavailableException {
      rethrow;
    } on Exception catch (e) {
      debugPrint('Failed to create identity: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to create identity');
    }
  }

  @override
  Future<Identity> importFromNsec(String nsec) async {
    final (:manager, :storedKey) = await _ensureInitialized();
    if (storedKey == _StoredKey.unknown) {
      throw const IdentityStorageUnavailableException();
    }

    try {
      // Import identity in Rust
      final rustIdentity = await manager.importFromNsec(nsec: nsec);
      await _storeNewKey(manager);

      return Identity(
        pubkeyHex: rustIdentity.pubkeyHex,
        npub: rustIdentity.npub,
        createdAt: _timestampToDateTime(rustIdentity.createdAt),
      );
    } on IdentityStorageUnavailableException {
      rethrow;
    } on Exception catch (_) {
      debugPrint('[Identity] Import failed');
      throw const IdentityServiceException('Failed to import identity');
    }
  }

  @override
  Future<String> exportNsec() async {
    final manager = (await _ensureInitialized()).manager;

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
      throw const IdentityServiceException(
        'Message hash must be exactly 32 bytes',
      );
    }

    final manager = (await _ensureInitialized()).manager;

    try {
      return await manager.sign(messageHash: messageHash.toList());
    } on Exception catch (e) {
      debugPrint('Failed to sign: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to sign');
    }
  }

  @override
  Future<String> getPubkeyHex() async {
    final manager = (await _ensureInitialized()).manager;

    try {
      return manager.pubkeyHex();
    } on Exception catch (e) {
      debugPrint('Failed to get pubkey: ${e.runtimeType}');
      throw const IdentityServiceException('Failed to get public key');
    }
  }

  @override
  Future<List<int>> getSecretBytes() async {
    final manager = (await _ensureInitialized()).manager;

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
      '$kDisplayNamePrefPrefix$pubkeyHex';

  @override
  Future<void> deleteIdentity() async {
    final manager = (await _ensureInitialized()).manager;

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
      _initialized = false;

      // Delete from secure storage
      await _storage.delete(key: identityStorageKey);

      // The display name lives in plain SharedPreferences — app-private, but
      // NOT encrypted, and not covered by the SQLCipher wipe. Left behind it
      // outlives "delete identity" as a plaintext record of who the user was,
      // alongside their pubkey in the key itself. Best-effort and isolated so
      // a preferences failure can neither block nor fail the deletion.
      try {
        final prefs = await SharedPreferences.getInstance();
        if (pubkeyHex != null) await prefs.remove(_displayNameKey(pubkeyHex));
        // Not keyed by the pubkey, so it goes even when that read failed: left
        // behind, the next identity's profile is fetched for a reset it never
        // had.
        await prefs.remove(kOwnNameReseedOwedKey);
      } on Object catch (e) {
        debugPrint('[Identity] display-name purge failed: ${e.runtimeType}');
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
