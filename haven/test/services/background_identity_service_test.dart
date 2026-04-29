/// Tests for `BackgroundIdentityService`.
///
/// The adapter is the only identity surface exposed to the background
/// isolate's `LocationSharingService`. These tests guard the privacy
/// invariant that secret material (sign / getSecretBytes / exportNsec)
/// is unreachable through this adapter — any future caller that adds
/// such a code path into the bg isolate must explicitly opt in by
/// implementing the method, rather than getting a silent fallback.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/background_identity_service.dart';
import 'package:haven/src/services/identity_service.dart';

/// Stub [NostrIdentityManager] that returns canned values without going
/// through Rust FFI. Only the methods invoked by
/// [BackgroundIdentityService] are implemented; the rest throw via
/// [noSuchMethod] to surface accidental new dependencies.
class _FakeNostrIdentityManager implements NostrIdentityManager {
  _FakeNostrIdentityManager({required this.identityLoaded, this.pubkey = ''});

  final bool identityLoaded;
  final String pubkey;

  @override
  bool hasIdentity() => identityLoaded;

  @override
  String pubkeyHex() {
    if (!identityLoaded) {
      throw StateError('No identity loaded');
    }
    return pubkey;
  }

  // Required because the FFI base type implements RustOpaqueInterface;
  // unit tests do not need a real opaque handle.
  @override
  bool get isDisposed => false;

  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
      'Fake stub: ${invocation.memberName} not implemented for tests',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BackgroundIdentityService', () {
    final expectedPubkey = 'a' * 64;

    test('getPubkeyHex returns the underlying manager pubkey', () async {
      final fake = _FakeNostrIdentityManager(
        identityLoaded: true,
        pubkey: expectedPubkey,
      );
      final adapter = BackgroundIdentityService(fake);

      expect(await adapter.getPubkeyHex(), equals(expectedPubkey));
    });

    test('getPubkeyHex throws IdentityServiceException when no identity '
        'is loaded — bg isolate fetch must not silently use empty pubkey', () {
      final fake = _FakeNostrIdentityManager(identityLoaded: false);
      final adapter = BackgroundIdentityService(fake);

      expect(adapter.getPubkeyHex, throwsA(isA<IdentityServiceException>()));
    });

    test('hasIdentity reflects underlying manager state', () async {
      final loaded = BackgroundIdentityService(
        _FakeNostrIdentityManager(identityLoaded: true, pubkey: 'a' * 64),
      );
      final missing = BackgroundIdentityService(
        _FakeNostrIdentityManager(identityLoaded: false),
      );

      expect(await loaded.hasIdentity(), isTrue);
      expect(await missing.hasIdentity(), isFalse);
    });

    // ------------------------------------------------------------------
    // PRIVACY INVARIANT: anything that exposes secret material or mutates
    // identity state MUST throw UnimplementedError. Adding such a code
    // path into the bg isolate would weaken Haven's secret-bytes
    // exposure window. A future contributor that wires getSecretBytes
    // into a bg call site should hit this test failure first and have
    // to deliberately decide.
    // ------------------------------------------------------------------
    final adapter = BackgroundIdentityService(
      _FakeNostrIdentityManager(identityLoaded: true, pubkey: expectedPubkey),
    );

    test('createIdentity throws UnimplementedError', () {
      expect(adapter.createIdentity, throwsA(isA<UnimplementedError>()));
    });

    test('importFromNsec throws UnimplementedError', () {
      expect(
        () => adapter.importFromNsec('nsec1abc'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('exportNsec throws UnimplementedError', () {
      expect(adapter.exportNsec, throwsA(isA<UnimplementedError>()));
    });

    test('sign throws UnimplementedError — bg isolate must not produce '
        'signatures', () {
      expect(
        () => adapter.sign(Uint8List(32)),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('getSecretBytes throws UnimplementedError — bg isolate must not '
        'expose secret material', () {
      expect(adapter.getSecretBytes, throwsA(isA<UnimplementedError>()));
    });

    test('deleteIdentity throws UnimplementedError', () {
      expect(adapter.deleteIdentity, throwsA(isA<UnimplementedError>()));
    });

    test('getDisplayName throws UnimplementedError', () {
      expect(adapter.getDisplayName, throwsA(isA<UnimplementedError>()));
    });

    test('setDisplayName throws UnimplementedError', () {
      expect(
        () => adapter.setDisplayName('name'),
        throwsA(isA<UnimplementedError>()),
      );
    });

    test('clearCache is a no-op (does not throw)', () async {
      // Adapter holds no cache of its own; the underlying manager
      // owns secret lifetime via its own teardown path.
      await adapter.clearCache();
    });

    test('getIdentity throws UnimplementedError', () {
      expect(adapter.getIdentity, throwsA(isA<UnimplementedError>()));
    });
  });
}
