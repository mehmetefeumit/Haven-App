/// Regression tests for [NostrIdentityService]'s identity-load retry
/// contract.
///
/// ## What broke, and why these tests exist
///
/// `_ensureInitialized` used to set `_initialized = true` unconditionally —
/// including when the secure-storage read produced no identity. Because that
/// flag short-circuits every later call, ONE unreadable read latched the whole
/// process into a logged-out state: nothing re-read storage, so `MapShell`
/// never started the receive plane (no live-sync engine, no KeyPackage
/// publish) until the app was killed and relaunched.
///
/// That is not hypothetical. An iOS Keychain entry written with
/// `first_unlock_this_device` can read back `null` while protected data is
/// momentarily unavailable — before first unlock, on a cold boot, or when
/// several `FlutterSecureStorage` instances race. It reddened the iOS
/// live-sync E2E lane: one null read, and the engine never started for the
/// rest of the run.
///
/// The contract these tests pin: **a load that produced no identity must not
/// latch.** Retry on the next access; latch only once a key is resident.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/nostr_identity_service.dart';

/// Minimal in-memory stand-in for the Rust identity manager.
///
/// Only the members these tests exercise are implemented; everything else
/// routes through [noSuchMethod] and would throw loudly if touched, so a
/// future code path that starts depending on more of the FFI surface fails
/// visibly instead of silently passing against a half-fake.
class _FakeIdentityManager implements NostrIdentityManager {
  int loadFromBytesCalls = 0;
  bool _identityLoaded = false;

  /// When set, [loadFromBytes] throws it — models corrupt stored bytes.
  Object? loadError;

  @override
  bool hasIdentity() => _identityLoaded;

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    loadFromBytesCalls++;
    final err = loadError;
    if (err != null) throw err;
    _identityLoaded = true;
    return PublicIdentity(
      pubkeyHex: 'ab' * 32,
      npub: 'npub1fake',
      createdAt: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Secure storage whose `read` result is scripted per call, so a transient
/// miss followed by a good read is reproducible.
class _ScriptedStorage extends FlutterSecureStorage {
  _ScriptedStorage(this._results);

  final List<String?> _results;
  int readCalls = 0;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final index = readCalls < _results.length ? readCalls : _results.length - 1;
    readCalls++;
    return _results[index];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final validSecret = base64Encode(Uint8List.fromList(List.filled(32, 7)));

  group('NostrIdentityService — identity load must not latch a miss', () {
    test(
      'a null storage read is retried on the next access (not cached)',
      () async {
        // First read misses (the transient iOS Keychain case), second succeeds.
        final storage = _ScriptedStorage(<String?>[null, validSecret]);
        final manager = _FakeIdentityManager();
        final service = NostrIdentityService(
          storage: storage,
          wipeTileCache: () async {},
          managerFactory: () async => manager,
        );

        expect(
          await service.hasIdentity(),
          isFalse,
          reason: 'the first read genuinely returned nothing',
        );
        expect(storage.readCalls, 1);

        // The regression: this second call used to short-circuit on the
        // latched `_initialized` flag and never touch storage again.
        expect(
          await service.hasIdentity(),
          isTrue,
          reason:
              'a miss must not be cached — the next access has to re-read '
              'storage so a transient Keychain failure self-heals',
        );
        expect(
          storage.readCalls,
          2,
          reason: 'the second access must actually hit secure storage again',
        );
      },
    );

    test('a successful load latches (storage is not re-read)', () async {
      final storage = _ScriptedStorage(<String?>[validSecret]);
      final manager = _FakeIdentityManager();
      final service = NostrIdentityService(
        storage: storage,
        wipeTileCache: () async {},
        managerFactory: () async => manager,
      );

      expect(await service.hasIdentity(), isTrue);
      expect(await service.hasIdentity(), isTrue);
      expect(await service.hasIdentity(), isTrue);

      expect(
        storage.readCalls,
        1,
        reason:
            'once a key is resident the flag must latch — retrying forever '
            'would hit the Keychain on every identity access',
      );
      expect(
        manager.loadFromBytesCalls,
        1,
        reason: 'the resident keypair must not be reloaded per access',
      );
    });

    test('a throwing load is retried rather than cached', () async {
      final storage = _ScriptedStorage(<String?>[validSecret]);
      final manager = _FakeIdentityManager()
        ..loadError = StateError('corrupt stored bytes');
      final service = NostrIdentityService(
        storage: storage,
        wipeTileCache: () async {},
        managerFactory: () async => manager,
      );

      expect(
        await service.hasIdentity(),
        isFalse,
        reason: 'the load threw, so no identity is resident',
      );
      // Recover: a later attempt must be allowed to succeed.
      manager.loadError = null;
      expect(
        await service.hasIdentity(),
        isTrue,
        reason: 'a failed load must not be latched into a permanent no-identity',
      );
      expect(storage.readCalls, 2);
    });

    test('the Rust manager is built once and reused across retries', () async {
      // Rebuilding per attempt would churn the in-memory (ZeroizeOnDrop)
      // keypair and could drop an identity an earlier attempt already loaded.
      final storage = _ScriptedStorage(<String?>[null, null, validSecret]);
      var factoryCalls = 0;
      final manager = _FakeIdentityManager();
      final service = NostrIdentityService(
        storage: storage,
        wipeTileCache: () async {},
        managerFactory: () async {
          factoryCalls++;
          return manager;
        },
      );

      await service.hasIdentity();
      await service.hasIdentity();
      await service.hasIdentity();

      expect(storage.readCalls, 3, reason: 'each miss re-reads');
      expect(
        factoryCalls,
        1,
        reason: 'the manager owns the keypair — build it exactly once',
      );
    });
  });
}
