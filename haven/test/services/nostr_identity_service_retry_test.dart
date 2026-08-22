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

import 'dart:async';
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
  PublicIdentity? getIdentity() => _identityLoaded
      ? PublicIdentity(pubkeyHex: 'ab' * 32, npub: 'npub1fake', createdAt: 0)
      : null;

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

/// Secure storage whose `read` blocks on [gate] before returning a fixed
/// result — lets a test hold several concurrent readers in flight at once,
/// so the in-flight guard can be observed rather than assumed.
class _GatedStorage extends FlutterSecureStorage {
  _GatedStorage(this._result);

  final String? _result;
  final Completer<void> gate = Completer<void>();
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
    readCalls++;
    await gate.future;
    return _result;
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

  group('NostrIdentityService — concurrent initialization is coalesced', () {
    test(
      'concurrent getIdentity() calls during startup construct exactly one '
      'manager',
      () async {
        // The Identity page fires 4-6 near-simultaneous getIdentity() calls
        // on open; without an in-flight guard each would race its own
        // manager construction and its own secure-storage read.
        final storage = _ScriptedStorage(<String?>[validSecret]);
        final manager = _FakeIdentityManager();
        final gate = Completer<void>();
        var factoryCalls = 0;
        final service = NostrIdentityService(
          storage: storage,
          wipeTileCache: () async {},
          managerFactory: () async {
            factoryCalls++;
            await gate.future;
            return manager;
          },
        );

        // Fired while the factory is still blocked on the gate, so every
        // call arrives before the first one could possibly have finished.
        final futures = List.generate(6, (_) => service.getIdentity());

        gate.complete();
        final results = await Future.wait(futures);

        expect(
          factoryCalls,
          1,
          reason:
              'only the leader call may construct a manager — every other '
              'concurrent caller must join its in-flight attempt instead',
        );
        for (final identity in results) {
          expect(identity, isNotNull);
          expect(identity!.pubkeyHex, 'ab' * 32);
        }
      },
    );

    test(
      'concurrent calls during startup issue exactly one secure-storage read',
      () async {
        final storage = _GatedStorage(validSecret);
        final manager = _FakeIdentityManager();
        final service = NostrIdentityService(
          storage: storage,
          wipeTileCache: () async {},
          managerFactory: () async => manager,
        );

        // Fired while the read is still blocked on the gate, so every call
        // arrives before the leader's read could possibly have settled.
        final futures = List.generate(5, (_) => service.getIdentity());

        storage.gate.complete();
        final results = await Future.wait(futures);

        expect(
          storage.readCalls,
          1,
          reason:
              'every concurrent caller must join the one in-flight read — '
              'without the guard, each would issue its own Keychain read',
        );
        for (final identity in results) {
          expect(identity, isNotNull);
          expect(identity!.pubkeyHex, 'ab' * 32);
        }
      },
    );
  });

  group(
    'NostrIdentityService — a manager-factory failure during startup',
    () {
      test(
        'propagates to every concurrent waiter (no hang), and a later '
        'call retries construction',
        () async {
          // Only the FIRST attempt is gated; once the gate opens it THROWS
          // rather than returning a manager, modelling `_managerFactory()`
          // itself failing outright (as opposed to a later storage-read
          // failure, already covered above). A later, non-concurrent retry
          // must be free to succeed, so this returns the real manager from
          // the second call on.
          final storage = _ScriptedStorage(<String?>[validSecret]);
          final manager = _FakeIdentityManager();
          final gate = Completer<void>();
          var factoryCalls = 0;
          final service = NostrIdentityService(
            storage: storage,
            wipeTileCache: () async {},
            managerFactory: () async {
              factoryCalls++;
              if (factoryCalls == 1) {
                await gate.future;
                throw StateError('manager construction failed');
              }
              return manager;
            },
          );

          // Fired while the factory is still blocked on the gate, so every
          // call arrives before the leader's attempt could possibly have
          // settled — exactly the coalescing window `_initCompleter` exists
          // for.
          final futures = List.generate(5, (_) => service.getIdentity());

          gate.complete();

          // Every waiter — the leader AND the 4 that joined its in-flight
          // attempt — must observe the failure. A hang here would mean a
          // waiter's `await inFlight.future` never settles; a silent `null`
          // would mean the failure was swallowed instead of surfaced.
          for (final future in futures) {
            await expectLater(
              future,
              throwsA(isA<StateError>()),
              reason: 'a concurrent waiter must observe the SAME failure the '
                  'leader constructing the manager hit, not hang or resolve',
            );
          }
          expect(
            factoryCalls,
            1,
            reason: 'only the leader call may construct a manager for this '
                'attempt — the other 4 must have joined it, not started '
                'their own',
          );

          // The in-flight completer is cleared in `finally` regardless of
          // success or failure, so a LATER, non-concurrent call must retry
          // rather than staying wedged on the failed attempt forever.
          final retried = await service.getIdentity();
          expect(
            factoryCalls,
            2,
            reason: 'a later call must construct the manager again rather '
                'than reusing the failed attempt',
          );
          expect(retried, isNotNull);
          expect(retried!.pubkeyHex, 'ab' * 32);
        },
      );
    },
  );
}
