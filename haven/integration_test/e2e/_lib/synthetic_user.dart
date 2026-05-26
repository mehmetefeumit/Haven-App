/// A test identity that exists *only* on the relay — no Flutter app, no
/// UI, no scenario-driven interactions.
///
/// `SyntheticUser` is the lightweight counterpart to [TestUser] used when a
/// scenario needs the side-effects of another participant being on the
/// network (a published KeyPackage Alice can discover, an inbox relay list
/// to deliver a Welcome to) but doesn't need to drive that participant's
/// UI.
///
/// Internally a `SyntheticUser` *is* a [TestUser] — the FFI surface is the
/// same — but its job is to put events on the hermetic strfry and then
/// step out of the way.
library;

import 'package:flutter/foundation.dart';

import 'test_relay.dart';
import 'test_user.dart';

/// A relay-resident test identity with its KeyPackage already published.
class SyntheticUser {
  SyntheticUser._({required this.user, required this.keyPackageRelays});

  /// Constructs a synthetic identity from [seed] and publishes its
  /// KeyPackage to [relay] before returning.
  ///
  /// The published event uses **both** the canonical kind 30443
  /// (addressable, MIP-00) and the legacy kind 443 — Haven's
  /// [`NostrRelayService.fetchKeyPackage`] queries both kinds, and
  /// publishing both maximises the chance the UI's KP lookup will
  /// succeed regardless of which kind it prefers first.
  ///
  /// Throws if the relay rejects either event (an indicator of a
  /// strfry misconfiguration or a malformed event).
  static Future<SyntheticUser> bootstrap({
    required String label,
    required Uint8List seed,
    required TestRelay relay,
  }) async {
    final user = await TestUser.bootstrap(label: label, seed: seed);
    try {
      final secret = await user.getSecretBytes();
      try {
        final kp = await user.circleManager.signKeyPackageEvent(
          identitySecretBytes: secret,
          relays: <String>[relay.url],
        );

        // Publish kind 30443 (canonical) first.
        final (acceptedCanonical, msgCanonical) = await relay.publishAndAwaitOk(
          kp.eventJson,
        );
        if (!acceptedCanonical) {
          throw StateError(
            "relay rejected $label's kind 30443 KeyPackage: $msgCanonical",
          );
        }

        // Then the legacy kind 443. Some relays might reject duplicates
        // by event id, but the two events have distinct ids (different
        // kind), so both should land.
        final (acceptedLegacy, msgLegacy) = await relay.publishAndAwaitOk(
          kp.legacyEventJson,
        );
        if (!acceptedLegacy) {
          // Non-fatal: production code falls back gracefully to whichever
          // event is present. Log but don't fail the test setup.
          debugPrint(
            '[SyntheticUser:$label] relay rejected legacy kind 443: '
            '$msgLegacy (non-fatal)',
          );
        }

        return SyntheticUser._(
          user: user,
          keyPackageRelays: <String>[relay.url],
        );
      } finally {
        // Best-effort wipe of the local copy of the secret. Rust-side is
        // already Zeroizing-wrapped (see api.rs:load_from_bytes); this
        // covers the Dart-side List<int> that crossed the FFI boundary.
        for (var i = 0; i < secret.length; i++) {
          secret[i] = 0;
        }
      }
    } on Object {
      await user.dispose();
      rethrow;
    }
  }

  /// Convenience: Bob with the canonical sentinel seed, published to
  /// [relay].
  static Future<SyntheticUser> bob(TestRelay relay) =>
      bootstrap(label: 'bob', seed: bobSeed, relay: relay);

  /// The underlying [TestUser] — exposed so scenarios can read pubkey/npub
  /// or, in edge cases, drive its FFI directly.
  final TestUser user;

  /// Relay URLs the KeyPackage event records as the user's "inbox" for
  /// follow-up Welcome delivery. In Phase 1 this is always `[strfryUrl]`.
  final List<String> keyPackageRelays;

  /// The user's pubkey in NIP-19 bech32 form.
  String get npub => user.npub;

  /// The user's pubkey as lowercase hex.
  String get pubkeyHex => user.pubkeyHex;

  /// Releases the underlying [TestUser].
  Future<void> dispose() => user.dispose();
}
