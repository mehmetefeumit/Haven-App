/// Regression tests for what [NostrIdentityService.deleteIdentity] leaves
/// behind.
///
/// ## What broke, and why these tests exist
///
/// `deleteIdentity` wiped the Rust manager, the secure-storage secret and the
/// encrypted tile cache — but not the display name, which lives in plain
/// `SharedPreferences` under `haven.display_name.<pubkeyHex>`. That is
/// app-private storage, not encrypted storage, and it is not covered by the
/// SQLCipher wipe. So "Delete identity" left a plaintext record of who the
/// user was, with their public key embedded in the preference key itself.
///
/// The ordering matters and is easy to get wrong: the preference is keyed by
/// the pubkey, so the pubkey has to be read *before* the manager is destroyed.
/// A fix that reads it afterwards silently no-ops, which is why the
/// "purges even though the manager is wiped" case is asserted explicitly.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _pubkeyHex = 'ab' * 32;
String _displayNameKey(String pubkeyHex) => 'haven.display_name.$pubkeyHex';

/// Minimal stand-in for the Rust identity manager.
///
/// Anything these tests do not exercise routes through [noSuchMethod] and
/// throws loudly, so a future code path that depends on more of the FFI
/// surface fails visibly rather than passing against a half-fake.
class _FakeIdentityManager implements NostrIdentityManager {
  bool _identityLoaded = false;
  bool deleted = false;

  /// When true, [pubkeyHex] throws — models the manager being unable to
  /// report the key (the fix must then skip the purge, not crash).
  bool pubkeyThrows = false;

  @override
  bool hasIdentity() => _identityLoaded;

  @override
  String pubkeyHex() {
    if (pubkeyThrows) throw StateError('no identity');
    return _pubkeyHex;
  }

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    _identityLoaded = true;
    return PublicIdentity(pubkeyHex: _pubkeyHex, npub: 'npub1fake', createdAt: 0);
  }

  @override
  Future<void> deleteIdentity() async {
    deleted = true;
    _identityLoaded = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Secure storage backed by an in-memory map.
class _MemoryStorage extends FlutterSecureStorage {
  _MemoryStorage(this._value);

  String? _value;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _value;

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _value = null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final validSecret = base64Encode(Uint8List.fromList(List.filled(32, 7)));

  NostrIdentityService buildService(_FakeIdentityManager manager) =>
      NostrIdentityService(
        storage: _MemoryStorage(validSecret),
        wipeTileCache: () async {},
        managerFactory: () async => manager,
      );

  group('deleteIdentity leaves no plaintext residue', () {
    test('purges the display name from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        _displayNameKey(_pubkeyHex): 'Quiet Wanderer',
      });
      final manager = _FakeIdentityManager();
      final service = buildService(manager);

      await service.deleteIdentity();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(_displayNameKey(_pubkeyHex)),
        isNull,
        reason: 'the display name outlived "delete identity"',
      );
      expect(manager.deleted, isTrue);
    });

    test('purges it even though the manager is wiped first', () async {
      // The pubkey must be captured BEFORE deletion, or the key cannot be
      // derived and the purge silently does nothing.
      SharedPreferences.setMockInitialValues(<String, Object>{
        _displayNameKey(_pubkeyHex): 'Quiet Wanderer',
      });
      final manager = _FakeIdentityManager();
      final service = buildService(manager);

      await service.deleteIdentity();

      expect(manager.hasIdentity(), isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_displayNameKey(_pubkeyHex)), isNull);
    });

    test('leaves other users\' preferences untouched', () async {
      final otherKey = _displayNameKey('cd' * 32);
      SharedPreferences.setMockInitialValues(<String, Object>{
        _displayNameKey(_pubkeyHex): 'Quiet Wanderer',
        otherKey: 'Someone Else',
        'haven.theme_mode': 'dark',
      });
      final service = buildService(_FakeIdentityManager());

      await service.deleteIdentity();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(_displayNameKey(_pubkeyHex)), isNull);
      expect(prefs.getString(otherKey), 'Someone Else');
      expect(prefs.getString('haven.theme_mode'), 'dark');
    });

    test('still deletes the identity when the pubkey cannot be read', () async {
      // A purge failure must never block or fail the deletion itself.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final manager = _FakeIdentityManager()..pubkeyThrows = true;
      final service = buildService(manager);

      await expectLater(service.deleteIdentity(), completes);
      expect(manager.deleted, isTrue);
    });

    test('wipes the encrypted map-tile cache', () async {
      // Every other test in this file (and nostr_identity_service_retry_test)
      // injects wipeTileCache as a no-op closure, so a regression that deletes
      // the `_wipeTileCache()` call from deleteIdentity would break nothing
      // there. This spy asserts the call is actually made.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      var tileCacheWiped = false;
      final manager = _FakeIdentityManager();
      final service = NostrIdentityService(
        storage: _MemoryStorage(validSecret),
        wipeTileCache: () async {
          tileCacheWiped = true;
        },
        managerFactory: () async => manager,
      );

      await service.deleteIdentity();

      expect(
        tileCacheWiped,
        isTrue,
        reason:
            'deleteIdentity must wipe the encrypted tile cache so a new '
            "identity never inherits the prior identity's cached map areas",
      );
    });
  });
}
