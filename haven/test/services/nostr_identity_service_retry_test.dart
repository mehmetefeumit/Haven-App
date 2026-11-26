/// Regression tests for [NostrIdentityService]'s identity-load contract.
///
/// ## What broke, and why these tests exist
///
/// `_ensureInitialized` used to set `_initialized = true` unconditionally —
/// including when the secure-storage read produced no identity. Because that
/// flag short-circuits every later call, ONE unreadable read latched the whole
/// process into a logged-out state: nothing re-read storage, so `MapShell`
/// never started the receive plane (no live-sync engine, no KeyPackage
/// publish) until the app was killed and relaunched. It reddened the iOS
/// live-sync E2E lane: the identity was present, one read produced none, and
/// the engine never started for the rest of the run.
///
/// The fix for that left a second hole: a read that failed looked exactly
/// like an empty store, so the create screen, resumed with a key stored but
/// unreadable, created a new key and wrote it over the stored one.
///
/// The contracts these tests pin:
/// * **A load that produced no stored identity must not latch.** Retry on the
///   next access; latch only once a stored key is resident.
/// * **A read that fails is not an empty store.** While storage cannot say
///   whether a key is stored, `hasIdentity` throws and `createIdentity` /
///   `importFromNsec` refuse, typed; a new key is written only where
///   `containsKey` finds none, and one that could not be written is not kept.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/identity_secure_storage.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/log_capture.dart';

final String _loadedPubkey = 'ab' * 32;
final String _createdPubkey = 'cd' * 32;

/// Minimal in-memory stand-in for the Rust identity manager.
///
/// Only the members these tests exercise are implemented; everything else
/// routes through [noSuchMethod] and would throw loudly if touched, so a
/// future code path that starts depending on more of the FFI surface fails
/// visibly instead of silently passing against a half-fake.
class _FakeIdentityManager implements NostrIdentityManager {
  int loadFromBytesCalls = 0;
  int createCalls = 0;
  int importCalls = 0;
  int deleteCalls = 0;
  String? _pubkey;

  /// When set, [loadFromBytes] throws it — models corrupt stored bytes.
  Object? loadError;

  /// The buffer each [loadFromBytes] was handed, as handed.
  final List<List<int>> loadedBuffers = [];

  /// When set, [deleteIdentity] waits on it before removing the key — the
  /// FFI await a concurrent caller can run inside.
  Completer<void>? deleteGate;

  @override
  bool hasIdentity() => _pubkey != null;

  @override
  PublicIdentity? getIdentity() => _pubkey == null
      ? null
      : PublicIdentity(pubkeyHex: _pubkey!, npub: 'npub1fake', createdAt: 0);

  @override
  String pubkeyHex() => _pubkey ?? (throw StateError('no identity'));

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    loadFromBytesCalls++;
    loadedBuffers.add(secretBytes);
    final err = loadError;
    if (err != null) throw err;
    _pubkey = _loadedPubkey;
    return getIdentity()!;
  }

  /// Like the Rust core: refuses when an identity is already resident.
  @override
  Future<PublicIdentity> createIdentity() async {
    createCalls++;
    if (_pubkey != null) throw Exception('identity exists');
    _pubkey = _createdPubkey;
    return getIdentity()!;
  }

  @override
  Future<PublicIdentity> importFromNsec({required String nsec}) async {
    importCalls++;
    if (_pubkey != null) throw Exception('identity exists');
    _pubkey = _createdPubkey;
    return getIdentity()!;
  }

  @override
  Future<Uint8List> getSecretBytes() async =>
      Uint8List.fromList(List.filled(32, 9));

  @override
  Future<void> deleteIdentity() async {
    deleteCalls++;
    await deleteGate?.future;
    _pubkey = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Secure storage holding [stored], whose reads are scripted per call so a
/// failed or empty read of a stored key is reproducible.
///
/// Each [_reads] entry answers one read, the last repeating: an [Exception]
/// is thrown, [_stored] returns what is stored, anything else (a `String` or
/// `null`) is returned as read.
class _ScriptedStorage extends FlutterSecureStorage {
  _ScriptedStorage(this._reads, {this.stored});

  final List<Object?> _reads;

  /// What the store actually holds.
  String? stored;
  int readCalls = 0;
  int containsKeyCalls = 0;
  int deleteCalls = 0;
  final List<String> writes = [];

  /// When set, [containsKey] answers it (a `bool`) or throws it.
  Object? containsKeyAnswer;

  /// Errors successive writes throw, one each; a write succeeds once these
  /// run out.
  final List<Exception> writeErrors = [];

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
    expect(key, identityStorageKey);
    final index = readCalls < _reads.length ? readCalls : _reads.length - 1;
    readCalls++;
    final answer = _reads[index];
    if (answer is Exception) throw answer;
    if (identical(answer, _stored)) return stored;
    return answer as String?;
  }

  @override
  Future<bool> containsKey({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    containsKeyCalls++;
    final answer = containsKeyAnswer;
    if (answer is Exception) throw answer;
    return answer as bool? ?? stored != null;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    expect(key, identityStorageKey);
    if (writeErrors.isNotEmpty) throw writeErrors.removeAt(0);
    writes.add(value!);
    stored = value;
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteCalls++;
    stored = null;
  }
}

/// [_ScriptedStorage] entry: the read returns what is stored.
const Object _stored = Object();

/// Secure storage whose `read` blocks on [gate] before returning a fixed
/// result — lets a test hold several concurrent readers in flight at once,
/// so the in-flight guard can be observed rather than assumed.
class _GatedStorage extends FlutterSecureStorage {
  _GatedStorage(this._result);

  final Object? _result;
  final Completer<void> gate = Completer<void>();
  int readCalls = 0;
  int writeCalls = 0;

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
    final result = _result;
    if (result is Exception) throw result;
    return result as String?;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    writeCalls++;
  }
}

/// A Keychain read failure as the iOS plugin reports one: the OSStatus in
/// `details`.
PlatformException _keychainLocked() => PlatformException(
  code: 'Unexpected security result code',
  message: 'Code: -25308, Message: User interaction is not allowed.',
  details: -25308,
);

const _unavailable = TypeMatcher<IdentityStorageUnavailableException>();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final validSecret = base64Encode(Uint8List.fromList(List.filled(32, 7)));

  NostrIdentityService serviceOver(
    FlutterSecureStorage storage,
    _FakeIdentityManager manager, {
    bool isIOS = false,
  }) => NostrIdentityService(
    storage: storage,
    wipeTileCache: () async {},
    keyringInitializer: () async {},
    managerFactory: () async => manager,
    isIOS: isIOS,
  );

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

      await expectLater(
        service.hasIdentity(),
        throwsA(_unavailable),
        reason:
            'the load threw: a key may be stored, so "no identity" would '
            'be a guess',
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

  group('NostrIdentityService — a manager-factory failure during startup', () {
    test('propagates to every concurrent waiter (no hang), and a later '
        'call retries construction', () async {
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
          reason:
              'a concurrent waiter must observe the SAME failure the '
              'leader constructing the manager hit, not hang or resolve',
        );
      }
      expect(
        factoryCalls,
        1,
        reason:
            'only the leader call may construct a manager for this '
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
        reason:
            'a later call must construct the manager again rather '
            'than reusing the failed attempt',
      );
      expect(retried, isNotNull);
      expect(retried!.pubkeyHex, 'ab' * 32);
    });
  });

  group('NostrIdentityService — a read that fails is not an empty store', () {
    test('hasIdentity throws typed when the read throws', () async {
      final service = serviceOver(
        _ScriptedStorage([_keychainLocked()], stored: validSecret),
        _FakeIdentityManager(),
      );

      await expectLater(service.hasIdentity(), throwsA(_unavailable));
    });

    test(
      'createIdentity refuses while every read throws: nothing is created or '
      'written, and the stored key is untouched',
      () async {
        final storage = _ScriptedStorage([
          _keychainLocked(),
        ], stored: validSecret);
        final manager = _FakeIdentityManager();
        final service = serviceOver(storage, manager);

        await expectLater(service.createIdentity(), throwsA(_unavailable));

        expect(manager.createCalls, 0, reason: 'no key may be generated');
        expect(storage.writes, isEmpty);
        expect(storage.containsKeyCalls, 0);
        expect(storage.deleteCalls, 0);
        expect(storage.stored, validSecret, reason: 'byte-identical');
      },
    );

    test(
      'a stored value that does not decode is refused, not replaced',
      () async {
        // What the plugin reports from Android's reset-on-error path in place
        // of the key — the path the shared options turn off.
        final storage = _ScriptedStorage([
          'Data has been reset',
        ], stored: validSecret);
        final manager = _FakeIdentityManager();
        final service = serviceOver(storage, manager);

        await expectLater(service.createIdentity(), throwsA(_unavailable));

        expect(manager.createCalls, 0);
        expect(storage.writes, isEmpty);
        expect(storage.stored, validSecret);
      },
    );

    test('a stored key that fails to load is refused, not replaced', () async {
      final storage = _ScriptedStorage([_stored], stored: validSecret);
      final manager = _FakeIdentityManager()
        ..loadError = StateError('corrupt stored bytes');
      final service = serviceOver(storage, manager);

      await expectLater(service.hasIdentity(), throwsA(_unavailable));
      await expectLater(service.createIdentity(), throwsA(_unavailable));

      expect(manager.createCalls, 0);
      expect(storage.writes, isEmpty);
      expect(storage.stored, validSecret);
    });

    test('importFromNsec refuses while the read throws', () async {
      final storage = _ScriptedStorage([
        _keychainLocked(),
      ], stored: validSecret);
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      await expectLater(
        service.importFromNsec('nsec1planted'),
        throwsA(_unavailable),
      );

      expect(manager.importCalls, 0);
      expect(storage.writes, isEmpty);
      expect(storage.stored, validSecret);
    });

    test('a refused create is not latched: the stored key, once readable, is '
        'used and never overwritten', () async {
      final storage = _ScriptedStorage([
        _keychainLocked(),
        _stored,
      ], stored: validSecret);
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      await expectLater(service.hasIdentity(), throwsA(_unavailable));
      // The screen's next step if it did not stop: the read now succeeds,
      // the stored key loads, and the create is refused as a duplicate.
      await expectLater(
        service.createIdentity(),
        throwsA(isA<IdentityServiceException>()),
      );

      expect(storage.readCalls, 2, reason: 'the failed read was not cached');
      expect(manager.hasIdentity(), isTrue);
      expect(manager.getIdentity()!.pubkeyHex, _loadedPubkey);
      expect(storage.writes, isEmpty);
      expect(storage.stored, validSecret);
    });

    test('an empty read creates and writes the key exactly once', () async {
      final storage = _ScriptedStorage([null]);
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      final created = await service.createIdentity();

      expect(created.pubkeyHex, _createdPubkey);
      expect(manager.createCalls, 1);
      expect(storage.containsKeyCalls, 1);
      expect(storage.writes, [base64Encode(List.filled(32, 9))]);
      expect(await service.hasIdentity(), isTrue);
      expect(storage.readCalls, 1, reason: 'a stored, resident key latches');
    });

    test('a key storage shows just before the write is never written over; the '
        'new one leaves memory', () async {
      // The read said nothing is stored (a non-UTF-8 value, or a race), but
      // the item exists: an iOS write to it updates, and a failed update
      // deletes it.
      final storage = _ScriptedStorage([null], stored: validSecret);
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      await expectLater(service.createIdentity(), throwsA(_unavailable));

      expect(storage.writes, isEmpty);
      expect(storage.deleteCalls, 0);
      expect(storage.stored, validSecret);
      expect(manager.deleteCalls, 1);
      expect(manager.hasIdentity(), isFalse);
    });

    test('a storage check that fails refuses the write the same way', () async {
      final storage = _ScriptedStorage([null])
        ..containsKeyAnswer = _keychainLocked();
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      await expectLater(service.createIdentity(), throwsA(_unavailable));

      expect(storage.writes, isEmpty);
      expect(manager.hasIdentity(), isFalse);
    });

    test(
      'a key whose write fails is not kept — and nothing else is deleted',
      () async {
        SharedPreferences.setMockInitialValues(<String, Object>{
          'haven.display_name.$_createdPubkey': 'Alice',
          kOwnNameReseedOwedKey: true,
        });
        final storage = _ScriptedStorage([null])
          ..writeErrors.add(PlatformException(code: 'write failed'));
        final manager = _FakeIdentityManager();
        var tileWipes = 0;
        final service = NostrIdentityService(
          storage: storage,
          wipeTileCache: () async => tileWipes++,
          keyringInitializer: () async {},
          managerFactory: () async => manager,
          isIOS: false,
        );

        await expectLater(
          service.createIdentity(),
          throwsA(isA<IdentityServiceException>()),
        );

        expect(manager.deleteCalls, 1, reason: 'the unstored key is dropped');
        expect(await service.hasIdentity(), isFalse);
        expect(storage.readCalls, 2, reason: 'nothing latched');
        expect(storage.deleteCalls, 0);
        expect(tileWipes, 0);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('haven.display_name.$_createdPubkey'), 'Alice');
        expect(prefs.getBool(kOwnNameReseedOwedKey), isTrue);
      },
    );

    test(
      'a duplicate create over a loaded key leaves that key resident',
      () async {
        final storage = _ScriptedStorage([_stored], stored: validSecret);
        final manager = _FakeIdentityManager();
        final service = serviceOver(storage, manager);
        expect(await service.hasIdentity(), isTrue);

        await expectLater(
          service.createIdentity(),
          throwsA(isA<IdentityServiceException>()),
        );

        expect(manager.hasIdentity(), isTrue);
        expect(manager.deleteCalls, 0);
        expect(storage.writes, isEmpty);
        expect(storage.containsKeyCalls, 0);
      },
    );

    test('callers that join one failing attempt are all refused, and nothing '
        'is created', () async {
      final storage = _GatedStorage(_keychainLocked());
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);

      final probe = service.hasIdentity();
      final create = service.createIdentity();
      storage.gate.complete();

      await expectLater(probe, throwsA(_unavailable));
      await expectLater(create, throwsA(_unavailable));
      expect(storage.readCalls, 1, reason: 'the two joined one attempt');
      expect(manager.createCalls, 0);
      expect(storage.writeCalls, 0);
    });

    test('a read while an unstored key is still in memory does not latch it: '
        'the next create reads storage again', () async {
      final storage = _ScriptedStorage([null])
        ..writeErrors.add(PlatformException(code: 'write failed'));
      final manager = _FakeIdentityManager()..deleteGate = Completer<void>();
      final service = serviceOver(storage, manager);

      final first = service.createIdentity();
      await pumpEventQueue();
      expect(
        manager.deleteCalls,
        1,
        reason: 'the failed write is removing the unstored key',
      );
      // A screen restore asking meanwhile: storage holds nothing, but the
      // manager still holds the key the write failed for.
      await service.hasIdentity();
      manager.deleteGate!.complete();
      await expectLater(first, throwsA(isA<IdentityServiceException>()));

      await service.createIdentity();

      expect(storage.readCalls, 3, reason: 'the retry read storage again');
      expect(manager.createCalls, 2);
      expect(storage.writes, hasLength(1));
    });

    test('a deleted identity is read from storage again', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final storage = _ScriptedStorage([_stored], stored: validSecret);
      final manager = _FakeIdentityManager();
      final service = serviceOver(storage, manager);
      expect(await service.hasIdentity(), isTrue);

      await service.deleteIdentity();

      expect(await service.hasIdentity(), isFalse);
      expect(storage.readCalls, 2);
    });

    test('the decoded key bytes are scrubbed once loaded (Rule 9)', () async {
      final manager = _FakeIdentityManager();
      final service = serviceOver(
        _ScriptedStorage([_stored], stored: validSecret),
        manager,
      );

      expect(await service.hasIdentity(), isTrue);

      expect(manager.loadedBuffers.single, List.filled(32, 0));
    });
  });

  group('NostrIdentityService — a failed read logs no identifier', () {
    const npub =
        'npub1plantedplantedplantedplantedplantedplantedplantedplanted0';
    final hexKey = 'e7' * 32;
    final planted = 'secret $hexKey of $npub';

    Future<LogCapture> loadFailing(Object error, {required bool isIOS}) async {
      final logs = LogCapture.install();
      final service = serviceOver(
        _ScriptedStorage([error], stored: validSecret),
        _FakeIdentityManager(),
        isIOS: isIOS,
      );
      await expectLater(service.hasIdentity(), throwsA(_unavailable));
      logs.assertContains('identity load failed (PlatformException');
      return logs;
    }

    test(
      'an iOS Keychain failure logs its OSStatus and nothing else',
      () async {
        final logs = await loadFailing(
          PlatformException(
            code: 'Unexpected',
            message: planted,
            details: -25308,
          ),
          isIOS: true,
        );

        logs
          ..assertContains('Keychain status -25308')
          ..assertNoNeedles([npub, hexKey]);
      },
    );

    test(
      'an Android failure logs neither its message nor its details',
      () async {
        final logs = await loadFailing(
          PlatformException(
            code: 'Exception encountered',
            message: planted,
            details: 'java.lang.Exception: $planted\n\tat Storage.read',
          ),
          isIOS: false,
        );

        logs.assertNoNeedles([npub, hexKey, 'java.lang']);
        expect(logs.joined, isNot(contains('status')));
      },
    );

    test('an int details logs no status off iOS', () async {
      final logs = await loadFailing(
        PlatformException(code: 'x', message: planted, details: -25308),
        isIOS: false,
      );

      expect(logs.joined, isNot(contains('-25308')));
      logs.assertNoNeedles([npub, hexKey]);
    });

    test('an iOS failure whose details is text logs no status', () async {
      final logs = await loadFailing(
        PlatformException(code: 'x', message: planted, details: planted),
        isIOS: true,
      );

      expect(logs.joined, isNot(contains('status')));
      logs.assertNoNeedles([npub, hexKey]);
    });

    test('a failed storage check before a write logs no identifier', () async {
      final logs = LogCapture.install();
      final storage = _ScriptedStorage([null])
        ..containsKeyAnswer = PlatformException(
          code: 'x',
          message: planted,
          details: planted,
        );
      final service = serviceOver(storage, _FakeIdentityManager(), isIOS: true);

      await expectLater(service.createIdentity(), throwsA(_unavailable));

      logs
        ..assertContains('identity storage check failed (PlatformException)')
        ..assertNoNeedles([npub, hexKey]);
    });
  });
}
