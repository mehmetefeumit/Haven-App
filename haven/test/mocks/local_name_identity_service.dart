/// An [IdentityService] holding an identity and a device-local display name,
/// for tests of which name a surface shows the user as.
library;

import 'dart:typed_data';

import 'package:haven/src/services/identity_service.dart';

/// Holds [localName] as `NostrIdentityService` holds its SharedPreferences
/// copy (a blank write removes it) and records every write. Members the
/// name never reaches are unimplemented.
class LocalNameIdentityService implements IdentityService {
  /// Creates the service with [identity] and a local name of [localName].
  LocalNameIdentityService({this.identity, this.localName});

  /// The identity [getIdentity] answers.
  final Identity? identity;

  /// The device-local display name.
  String? localName;

  /// When set, [setDisplayName] throws.
  bool throwOnSet = false;

  /// Every [setDisplayName] argument, in call order.
  final List<String?> setDisplayNameCalls = [];

  @override
  Future<String?> getDisplayName() async => localName;

  @override
  Future<void> setDisplayName(String? name) async {
    if (throwOnSet) throw const IdentityServiceException('boom');
    setDisplayNameCalls.add(name);
    final trimmed = name?.trim();
    localName = trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  @override
  Future<Identity?> getIdentity() async => identity;

  @override
  Future<bool> hasIdentity() async => identity != null;

  @override
  Future<String> getPubkeyHex() async => identity!.pubkeyHex;

  @override
  Future<Identity> createIdentity() => throw UnimplementedError();

  @override
  Future<Identity> importFromNsec(String nsec) => throw UnimplementedError();

  @override
  Future<void> deleteIdentity() => throw UnimplementedError();

  @override
  Future<String> exportNsec() => throw UnimplementedError();

  @override
  Future<String> sign(Uint8List messageHash) => throw UnimplementedError();

  @override
  Future<List<int>> getSecretBytes() => throw UnimplementedError();

  @override
  Future<void> clearCache() async {}
}
