/// Pins the redaction contract on [NostrIdentityService]'s async FFI calls.
///
/// ## What broke, and why these tests exist
///
/// Security Rule 8 says no raw FFI error may reach the UI: an `anyhow` string
/// crossing the bridge can carry MLS group ids, storage paths, or other
/// internal state. Every one of these methods therefore wraps its FFI call in
/// a `try` whose `catch` throws a generic [IdentityServiceException] instead.
///
/// Three of them returned the future WITHOUT awaiting it:
///
/// ```dart
/// try {
///   return manager.exportNsec();   // rejects LATER, outside this try
/// } on Exception catch (_) {
///   throw const IdentityServiceException('Failed to export secret key');
/// }
/// ```
///
/// A `return` of an un-awaited future leaves the `try` before the future
/// settles, so the rejection is delivered to the CALLER and the catch never
/// runs. The generic message was dead code and the raw Rust error was what
/// callers actually saw. `await` inside the `try` is the whole fix, and these
/// tests fail without it: the raw sentinel escapes.
///
/// `getPubkeyHex` and `hasIdentity` are deliberately not covered here — those
/// FFI methods are `#[frb(sync)]`, so they throw synchronously inside the try
/// and were never affected.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart'
    show NostrIdentityManager, PublicIdentity;
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/nostr_identity_service.dart';

/// Text no caller may ever see: it stands in for the internal state a real
/// `anyhow` error carries across the bridge.
const _sensitive = 'mls group 9f3a1c secret material at /data/haven/mls.db';

/// A manager whose ASYNC methods reject the way a failing FFI call does.
///
/// Only the members under test are implemented; anything else routes through
/// [noSuchMethod], so a method that starts depending on more of the FFI
/// surface fails visibly rather than passing against a half-fake.
class _FailingIdentityManager implements NostrIdentityManager {
  bool _identityLoaded = false;

  @override
  bool hasIdentity() => _identityLoaded;

  @override
  Future<PublicIdentity> loadFromBytes({required List<int> secretBytes}) async {
    _identityLoaded = true;
    return PublicIdentity(pubkeyHex: 'ab' * 32, npub: 'npub1fake', createdAt: 0);
  }

  @override
  Future<String> exportNsec() async => throw Exception(_sensitive);

  @override
  Future<String> sign({required List<int> messageHash}) async =>
      throw Exception(_sensitive);

  @override
  Future<Uint8List> getSecretBytes() async => throw Exception(_sensitive);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Serves one stored secret, so `_ensureInitialized` reaches the manager.
class _StoredSecretStorage extends FlutterSecureStorage {
  _StoredSecretStorage(this._secret);

  final String _secret;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _secret;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  NostrIdentityService buildService() => NostrIdentityService(
    storage: _StoredSecretStorage(
      base64Encode(Uint8List.fromList(List.filled(32, 7))),
    ),
    wipeTileCache: () async {},
    managerFactory: () async => _FailingIdentityManager(),
  );

  /// Runs [call] and returns what it threw, failing the test if it returned.
  Future<Object> thrownBy(Future<void> Function() call) async {
    try {
      await call();
    } on Object catch (e) {
      return e;
    }
    fail('the failing FFI call must not resolve successfully');
  }

  group('NostrIdentityService — a failing async FFI call is redacted', () {
    test('exportNsec surfaces a generic exception, never the FFI text', () async {
      final service = buildService();

      final error = await thrownBy(service.exportNsec);

      expect(
        error,
        isA<IdentityServiceException>().having(
          (e) => e.message,
          'message',
          'Failed to export secret key',
        ),
        reason: 'the catch must convert the FFI failure, not be bypassed by a '
            'returned future that settles outside the try',
      );
      expect(
        error.toString(),
        isNot(contains(_sensitive)),
        reason: 'Security Rule 8: no raw FFI error text may reach a caller',
      );
    });

    test('sign surfaces a generic exception, never the FFI text', () async {
      final service = buildService();

      final error = await thrownBy(
        () => service.sign(Uint8List.fromList(List.filled(32, 1))),
      );

      expect(
        error,
        isA<IdentityServiceException>().having(
          (e) => e.message,
          'message',
          'Failed to sign',
        ),
      );
      expect(error.toString(), isNot(contains(_sensitive)));
    });

    test(
      'getSecretBytes surfaces a generic exception, never the FFI text',
      () async {
        final service = buildService();

        final error = await thrownBy(service.getSecretBytes);

        expect(
          error,
          isA<IdentityServiceException>().having(
            (e) => e.message,
            'message',
            'Failed to get secret bytes',
          ),
        );
        expect(error.toString(), isNot(contains(_sensitive)));
      },
    );
  });
}
