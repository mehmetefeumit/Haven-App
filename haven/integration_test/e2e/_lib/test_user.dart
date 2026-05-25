/// A single E2E test identity (Alice or Bob) bound to an isolated
/// SQLCipher data directory and an in-memory keyring.
///
/// `TestUser` is the per-role aggregate that scenarios drive. It owns a
/// [NostrIdentityManager] + [CircleManagerFfi] backed by a deterministic
/// ephemeral seed.
///
/// ## Privacy guardrails
///
/// Seeds are **deterministic per CI run** but **ephemeral across runs**:
/// each pipeline invocation generates fresh 32-byte seeds in CI workflow
/// setup, exports them via dart-define, and never persists them. Combined
/// with the hermetic strfry relay, this means test pubkeys cannot reach
/// any production relay even if the override mechanism were bypassed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/nostr_identity_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Convenience: lowercase hex encoding of [bytes].
String bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Convenience: decodes a 64-char hex string into a 32-byte list.
Uint8List hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw ArgumentError.value(hex, 'hex', 'odd-length hex string');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Canonical sentinel seed for the Alice role.
///
/// Recognizable: 32 bytes of `0x01`. Hermetic relay only.
final Uint8List aliceSeed = Uint8List.fromList(List<int>.filled(32, 1));

/// Canonical sentinel seed for the Bob role.
///
/// Recognizable: 32 bytes of `0x02`. Hermetic relay only.
final Uint8List bobSeed = Uint8List.fromList(List<int>.filled(32, 2));

/// A test identity bound to its own data directory.
///
/// `TestUser` deliberately exposes the underlying [identity] and
/// [circleManager] handles — scenarios sometimes need to call FFI
/// methods directly (e.g. to assert local state independently of the UI).
class TestUser {
  TestUser._({
    required this.label,
    required this.seed,
    required this.dataDir,
    required this.identity,
    required this.circleManager,
    required this.pubkeyHex,
    required this.npub,
  });

  /// Boots the global Rust bridge, installs the in-memory keyring and
  /// the relay override, and prepares for [TestUser] construction.
  ///
  /// Call once per test process, before any `TestUser.bootstrap(...)` calls.
  /// The keyring install is idempotent; the relay override is install-once
  /// per process (a second call throws — guard with `try` if needed).
  ///
  /// ## Privacy guard
  ///
  /// Every URL in [relays] must resolve to a loopback / emulator-host
  /// address. Public relays are rejected to prevent a misconfigured
  /// `--dart-define=HAVEN_E2E_RELAY=wss://relay.damus.io` from publishing
  /// test seed pubkeys to a public relay. Override the guard by passing
  /// `allowPublicRelay: true`, only with explicit user authorization and
  /// non-sentinel seeds.
  static Future<void> bootstrapProcess({
    required List<String> relays,
    bool allowPublicRelay = false,
  }) async {
    if (!allowPublicRelay) {
      for (final url in relays) {
        if (!_isLoopback(url)) {
          throw StateError(
            'E2E tests must use a loopback relay URL; got "$url". '
            'Override with allowPublicRelay: true only with non-sentinel '
            'seeds.',
          );
        }
      }
    }
    await RustLib.init();
    // Install the in-memory keyring backend BEFORE any code path touches
    // the platform keyring. On Linux CI runners there is no D-Bus Secret
    // Service; on emulators we deliberately want process-scoped state.
    await useInMemoryKeyringForTest();
    // Redirect every relay-resolution call site to the hermetic strfry.
    setDefaultRelaysForTest(relays: relays);
    // Defense in depth: confirm the override actually propagated. A silent
    // failure here would leave the suite hitting production relays.
    final effective = defaultRelays();
    if (!_listsEqual(effective, relays)) {
      throw StateError(
        'Relay override did not propagate: expected $relays, '
        'got $effective. The OnceLock may already be set, or the '
        'debug_assertions build flag is off.',
      );
    }
  }

  /// Returns `true` if [url] resolves to a loopback / emulator-host alias.
  static bool _isLoopback(String url) {
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException {
      return false;
    }
    return uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        uri.host == '10.0.2.2' || // Android emulator host-loopback alias
        uri.host == '::1';
  }

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Constructs a `TestUser` from a deterministic ephemeral seed.
  ///
  /// Each `TestUser` gets its own temp directory so two roles in the
  /// same process don't share SQLCipher state.
  static Future<TestUser> bootstrap({
    required String label,
    required Uint8List seed,
  }) async {
    if (seed.length != 32) {
      throw ArgumentError.value(
        seed,
        'seed',
        'seed must be exactly 32 bytes',
      );
    }
    final dataDir =
        await Directory.systemTemp.createTemp('haven_e2e_${label}_');
    final identity = await NostrIdentityManager.newInstance();
    final publicIdentity =
        await identity.loadFromBytes(secretBytes: seed);
    final circleManager =
        await CircleManagerFfi.newInstance(dataDir: dataDir.path);
    return TestUser._(
      label: label,
      seed: Uint8List.fromList(seed),
      dataDir: dataDir,
      identity: identity,
      circleManager: circleManager,
      pubkeyHex: publicIdentity.pubkeyHex,
      npub: publicIdentity.npub,
    );
  }

  /// Convenience: Alice with the canonical sentinel seed.
  static Future<TestUser> alice() =>
      bootstrap(label: 'alice', seed: aliceSeed);

  /// Convenience: Bob with the canonical sentinel seed.
  static Future<TestUser> bob() => bootstrap(label: 'bob', seed: bobSeed);

  /// Writes [seed] into `flutter_secure_storage` and flips all onboarding
  /// flags so the next `HavenApp` pump skips onboarding and lands
  /// directly on the map shell with the deterministic identity active.
  ///
  /// Call **before** `tester.pumpWidget(...)`. Idempotent — overwriting
  /// the storage entry is harmless.
  ///
  /// ## Why pre-seed?
  ///
  /// Multi-process scenarios (Phase 2+) need both Alice and Bob to know
  /// each other's pubkey for the inviter to enter the invitee's npub.
  /// Driving the random-keypair onboarding UI would defeat that — each
  /// run would produce different pubkeys. Pre-seeding with the
  /// sentinel `aliceSeed` / `bobSeed` gives both processes a stable,
  /// pre-known peer pubkey without bypassing any production code path:
  /// the app's identity-loading sequence (read storage → `loadFromBytes`
  /// → identity provider) is exactly what production runs.
  static Future<void> preSeedIdentityAndSkipOnboarding({
    required Uint8List seed,
  }) async {
    if (seed.length != 32) {
      throw ArgumentError.value(seed, 'seed', 'seed must be exactly 32 bytes');
    }
    // 1. Identity into secure storage. Format mirrors
    //    `NostrIdentityService.createIdentity` (base64-encoded raw bytes
    //    under key `'haven.nostr.identity'`).
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    await storage.write(
      key: identityStorageKeyForTesting,
      value: base64Encode(seed),
    );

    // 2. Mark onboarding complete so AppRouter skips straight to MapShell.
    //    Production main.dart also writes these via
    //    OnboardingController.markCompleted().
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kOnboardingIntroSeenKey, true);
    await prefs.setBool(kOnboardingDisplayNameSetKey, true);
    await prefs.setBool(kOnboardingCompletedKey, true);
  }

  /// Removes the seeded identity + clears onboarding flags. Call from
  /// `tearDownAll` so a re-run of the same test process starts fresh.
  static Future<void> clearPreSeededIdentity() async {
    const storage = FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    );
    await storage.delete(key: identityStorageKeyForTesting);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(kOnboardingIntroSeenKey);
    await prefs.remove(kOnboardingDisplayNameSetKey);
    await prefs.remove(kOnboardingCompletedKey);
  }

  /// Short identifier used in logs and temp-dir names ("alice", "bob").
  final String label;

  /// The deterministic seed bytes used to construct this identity.
  ///
  /// Held only to allow re-creating the same identity in a follow-on
  /// process; never logged or shared with the relay.
  final Uint8List seed;

  /// Per-user temp directory containing this role's SQLCipher state.
  final Directory dataDir;

  /// The user's Nostr identity manager.
  final NostrIdentityManager identity;

  /// The user's circle manager (MLS + storage).
  final CircleManagerFfi circleManager;

  /// The user's public key as lowercase hex.
  final String pubkeyHex;

  /// The user's public key in NIP-19 bech32 form (`npub1...`).
  ///
  /// Use this when the UI accepts an npub string (the member-search input
  /// is the primary example) so the test doesn't have to perform its own
  /// bech32 encoding.
  final String npub;

  /// Returns the 32 secret bytes of this identity.
  ///
  /// **Test-only.** Production code should never round-trip the secret
  /// through Dart memory; tests need it because they construct
  /// `MemberKeyPackageFfi` for the partner role.
  Future<Uint8List> getSecretBytes() => identity.getSecretBytes();

  /// Releases the temp directory and the FFI handles.
  Future<void> dispose() async {
    try {
      await dataDir.delete(recursive: true);
    } on Object catch (e) {
      debugPrint('[TestUser:$label] temp-dir cleanup failed: $e');
    }
  }
}
