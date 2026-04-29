/// Minimal `IdentityService` adapter for the background isolate.
///
/// The background `LocationSharingService` only needs to resolve the
/// user's own pubkey hex once per process so that self-broadcasts can be
/// filtered before they hit the SQLCipher last-known store
/// (`location_sharing_service.dart::_ownPubkeyHex`). Implementing the
/// full `IdentityService` surface in the bg isolate would require
/// re-loading secret bytes for signing — a security regression we
/// explicitly avoid here.
///
/// All methods other than `getPubkeyHex` throw `UnimplementedError`;
/// the background fetch path never invokes them. If a future code path
/// adds new identity-dependent calls into the background isolate, the
/// resulting test failure should prompt a deliberate review rather than
/// silent fallback behaviour.
library;

import 'dart:typed_data';

import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/identity_service.dart';

/// [IdentityService] adapter that delegates pubkey lookups to a pre-loaded
/// [NostrIdentityManager].
///
/// Construction does not perform any I/O — the caller must have already
/// loaded the identity into the manager via `loadFromBytes`. If the
/// manager has no identity loaded, [getPubkeyHex] throws.
class BackgroundIdentityService implements IdentityService {
  /// Creates a [BackgroundIdentityService] backed by an already-loaded
  /// [NostrIdentityManager].
  BackgroundIdentityService(this._identityManager);

  final NostrIdentityManager _identityManager;

  /// Returns the loaded identity's pubkey as 64-character hex.
  ///
  /// Wrapped in `Future` to satisfy [IdentityService.getPubkeyHex],
  /// but the underlying `pubkeyHex()` FFI call is synchronous and
  /// performs no I/O — no secret-storage rehydration happens here.
  @override
  Future<String> getPubkeyHex() async {
    if (!_identityManager.hasIdentity()) {
      throw const IdentityServiceException(
        'No identity loaded in background isolate',
      );
    }
    return _identityManager.pubkeyHex();
  }

  @override
  Future<bool> hasIdentity() async => _identityManager.hasIdentity();

  // ---------------------------------------------------------------------------
  // The remaining surface is unused in the background fetch path. Intentional
  // hard failures preserve the security invariant that the bg isolate does not
  // touch secret material beyond what is already loaded for publishing.
  // ---------------------------------------------------------------------------

  @override
  Future<Identity?> getIdentity() => throw UnimplementedError(
    'BackgroundIdentityService does not support getIdentity',
  );

  @override
  Future<Identity> createIdentity() => throw UnimplementedError(
    'BackgroundIdentityService does not support createIdentity',
  );

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError(
    'BackgroundIdentityService does not support importFromNsec',
  );

  @override
  Future<String> exportNsec() => throw UnimplementedError(
    'BackgroundIdentityService does not support exportNsec',
  );

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError(
    'BackgroundIdentityService does not support sign',
  );

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError(
    'BackgroundIdentityService does not support getSecretBytes',
  );

  @override
  Future<void> deleteIdentity() => throw UnimplementedError(
    'BackgroundIdentityService does not support deleteIdentity',
  );

  @override
  Future<String?> getDisplayName() => throw UnimplementedError(
    'BackgroundIdentityService does not support getDisplayName',
  );

  @override
  Future<void> setDisplayName(String? name) => throw UnimplementedError(
    'BackgroundIdentityService does not support setDisplayName',
  );

  @override
  Future<void> clearCache() async {
    // No-op: this adapter holds no cache; secret material lives in the
    // underlying [NostrIdentityManager] which the bg task tears down via
    // its own onDestroy path.
  }
}
