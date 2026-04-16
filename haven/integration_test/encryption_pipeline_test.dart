/// Integration tests for the Dart→Rust→Dart location encryption pipeline.
///
/// These tests exercise the REAL FFI boundary to catch classes of bug that
/// mocked unit tests cannot:
///
/// - Serialization errors in the Nostr event JSON produced by Rust
/// - FFI type-conversion bugs (e.g., lat/lon truncation, wrong field names)
/// - Accidental plaintext coordinate leakage inside event content or tags
/// - Ephemeral-key invariant violations (outer event pubkey must differ from
///   the sender's identity pubkey, and must be unique per message)
/// - MLS group ID leakage into event JSON (MIP-00 Rule 4)
/// - Missing or empty h-tag (breaks relay routing)
/// - h-tag value not matching nostrGroupId hex (MIP-00 Rule 4)
/// - Missing or out-of-range expiration tag
/// - Empty or non-base64 ciphertext (silent no-op regression)
///
/// The test creates a minimal two-party MLS group entirely in-process using
/// real Rust cryptography via the FFI bridge, then encrypts a location with
/// well-known sentinel coordinates and asserts on the resulting event JSON.
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` calls `init_keyring_store()` internally,
/// which requires a live platform keyring backend:
/// - Linux: D-Bus Secret Service (GNOME Keyring, KDE Wallet, or KeePassXC)
/// - macOS/iOS: Keychain
/// - Android: Android Keystore (NDK context must be initialised)
///
/// If the keyring is unavailable the test skips cleanly with a descriptive
/// message rather than failing.  All other assertions are unconditional once
/// the keyring is confirmed to be available.
///
/// ## Running
///
/// ```sh
/// cd haven && flutter test integration_test/encryption_pipeline_test.dart
/// ```
///
/// Requires a connected device or emulator.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

/// Sentinel latitude that would be unmistakable in any plaintext leak.
const double _sentinelLat = 12.345678;

/// Sentinel longitude that would be unmistakable in any plaintext leak.
const double _sentinelLon = 87.654321;

/// Second sentinel coordinates for the ephemeral-key-uniqueness assertion.
const double _sentinelLat2 = 13.456789;
const double _sentinelLon2 = 89.876543;

/// Prefixes of the sentinel values to catch precision-stripped variants.
///
/// We check both the full value and shorter prefixes because a Rust
/// serialiser could round/truncate the double before embedding it.
/// The 1-decimal and integer-prefix forms catch lossy rounding regressions.
const List<String> _forbiddenLatSubstrings = [
  '12.345678',
  '12.34567',
  '12.3456',
  '12.345',
  '12.34',
  '12.3',
  '12.',
];
const List<String> _forbiddenLonSubstrings = [
  '87.654321',
  '87.65432',
  '87.6543',
  '87.654',
  '87.65',
  '87.6',
  '87.',
];

/// Forbidden substrings for the second sentinel coordinates.
const List<String> _forbiddenLatSubstrings2 = [
  '13.456789',
  '13.45678',
  '13.4567',
  '13.456',
  '13.45',
  '13.4',
  '13.',
];
const List<String> _forbiddenLonSubstrings2 = [
  '89.876543',
  '89.87654',
  '89.8765',
  '89.876',
  '89.87',
  '89.8',
  '89.',
];

/// Converts a [Uint8List] to a lowercase hex string.
String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  group('Location encryption pipeline (FFI boundary)', () {
    test('kind 445 event JSON contains no plaintext coordinates and uses '
        'ephemeral pubkey', () async {
      // ----------------------------------------------------------------
      // 1. Verify keyring availability — skip gracefully if unavailable.
      //    CircleManagerFfi.newInstance calls init_keyring_store() and
      //    get_or_create_circle_db_key() internally; both require a live
      //    platform keyring backend.
      // ----------------------------------------------------------------
      try {
        await initKeyringStore();
      } on Object catch (e) {
        // Platform keyring not available (e.g., no D-Bus Secret Service
        // on this Linux runner, or Keychain not unlocked on iOS).
        // Skip rather than fail so CI environments without a keyring
        // don't regress the suite.
        debugPrint(
          '[encryption_pipeline_test] Keyring unavailable, skipping: '
          '${e.runtimeType}',
        );
        return;
      }

      // ----------------------------------------------------------------
      // 2. Set up isolated temp directories for Alice and Bob.
      //    Each CircleManagerFfi instance needs its own data directory
      //    because MDK writes SQLite state at a fixed path inside it.
      // ----------------------------------------------------------------
      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_enc_test_alice_',
      );
      final bobDir = await Directory.systemTemp.createTemp(
        'haven_enc_test_bob_',
      );

      try {
        // --------------------------------------------------------------
        // 3. Create two independent Nostr identities.
        // --------------------------------------------------------------
        final aliceIdManager = await NostrIdentityManager.newInstance();
        await aliceIdManager.createIdentity();
        final aliceSecretBytes = await aliceIdManager.getSecretBytes();
        final alicePubkeyHex = aliceIdManager.pubkeyHex();

        final bobIdManager = await NostrIdentityManager.newInstance();
        await bobIdManager.createIdentity();
        final bobSecretBytes = await bobIdManager.getSecretBytes();

        // --------------------------------------------------------------
        // 4. Initialise two CircleManagerFfi instances (separate stores).
        // --------------------------------------------------------------
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );
        final bobManager = await CircleManagerFfi.newInstance(
          dataDir: bobDir.path,
        );

        // --------------------------------------------------------------
        // 5. Bob creates and signs a key package event for Alice to use
        //    when building the MLS group.
        // --------------------------------------------------------------
        const testRelays = <String>[];

        final bobKpResult = await bobManager.signKeyPackageEvent(
          identitySecretBytes: bobSecretBytes,
          relays: testRelays,
        );

        // --------------------------------------------------------------
        // 6. Alice creates a circle with Bob as the sole member.
        //    Pass Bob's signed key package event JSON inside a
        //    MemberKeyPackageFfi so the Rust layer can consume it.
        // --------------------------------------------------------------
        final creationResult = await aliceManager.createCircle(
          identitySecretBytes: aliceSecretBytes,
          members: [
            MemberKeyPackageFfi(
              keyPackageJson: bobKpResult.eventJson,
              inboxRelays: const [],
              nip65Relays: const [],
            ),
          ],
          name: 'Enc Pipeline Test Circle',
          circleType: 'location_sharing',
          relays: const [],
          creatorFallbackRelays: const [],
        );

        final mlsGroupId = creationResult.circle.mlsGroupId;
        final mlsGroupIdHex = _bytesToHex(Uint8List.fromList(mlsGroupId));
        final nostrGroupIdHex = _bytesToHex(
          Uint8List.fromList(creationResult.circle.nostrGroupId),
        );

        // Alice's pending commit (from adding Bob) must be merged before
        // she can send messages. This mirrors what the production code
        // does after a successful relay publish.
        await aliceManager.finalizePendingCommit(
          mlsGroupId: Uint8List.fromList(mlsGroupId),
        );

        // --------------------------------------------------------------
        // 7. Bob processes the gift-wrapped Welcome and accepts it so
        //    both parties share the same MLS epoch.
        //
        //    Note: encryptLocation does NOT require the recipient to
        //    have accepted yet (the sender only needs their own group
        //    state). However we also want to keep the test semantically
        //    correct — a group where the creator has merged their commit.
        // --------------------------------------------------------------
        if (creationResult.welcomeEvents.isNotEmpty) {
          final welcomeJson = creationResult.welcomeEvents.first.eventJson;

          try {
            final invitation = await bobManager.processGiftWrappedInvitation(
              identitySecretBytes: bobSecretBytes,
              giftWrapEventJson: welcomeJson,
            );
            // `null` means the wrapper was already processed on a prior
            // iteration of this test — safe to skip the accept.
            if (invitation != null) {
              await bobManager.acceptInvitation(
                mlsGroupId: invitation.mlsGroupId,
              );
            }
          } on Object catch (e) {
            // Invitation processing is best-effort for this test.
            // The critical assertion (encrypt → opaque JSON) does not
            // depend on Bob having accepted.
            debugPrint(
              '[encryption_pipeline_test] Bob invitation processing failed '
              '(non-critical for encryption assertion): ${e.runtimeType}',
            );
          }
        }

        // Capture wall-clock seconds before the first encrypt call so the
        // expiration window assertion is anchored to roughly "now".
        final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        // --------------------------------------------------------------
        // 8. Alice encrypts the sentinel location (first message).
        // --------------------------------------------------------------
        final encrypted = await aliceManager.encryptLocation(
          mlsGroupId: Uint8List.fromList(mlsGroupId),
          senderPubkeyHex: alicePubkeyHex,
          latitude: _sentinelLat,
          longitude: _sentinelLon,
          retentionSecs: BigInt.from(3600),
        );

        final eventJson = encrypted.eventJson;

        // ---- Assertion 1: event kind ----
        // The JSON must contain `"kind":445`.
        expect(
          eventJson,
          contains('"kind":445'),
          reason: 'Outer event must be kind 445 (Marmot group message)',
        );

        // ---- Assertion 2: h-tag present and non-empty ----
        // The h-tag carries the nostrGroupId for relay routing.
        // It always appears as ["h","<hex>"] in the tags array.
        expect(
          eventJson,
          contains('"h"'),
          reason: 'kind 445 event must carry an h-tag for relay routing',
        );

        // nostrGroupId from the FFI result must be 32 bytes (non-empty).
        expect(
          encrypted.nostrGroupId.length,
          equals(32),
          reason: 'nostrGroupId must be exactly 32 bytes',
        );

        // ---- Assertion 3: no plaintext latitude ----
        for (final forbidden in _forbiddenLatSubstrings) {
          expect(
            eventJson,
            isNot(contains(forbidden)),
            reason:
                'Encrypted event content must not contain plaintext '
                'latitude substring "$forbidden"',
          );
        }

        // ---- Assertion 4: no plaintext longitude ----
        for (final forbidden in _forbiddenLonSubstrings) {
          expect(
            eventJson,
            isNot(contains(forbidden)),
            reason:
                'Encrypted event content must not contain plaintext '
                'longitude substring "$forbidden"',
          );
        }

        // ---- Assertion 5: sender pubkey not in event JSON ----
        // The MLS-encrypted content is opaque; the sender's real pubkey
        // must never appear inside it (case-insensitive check covers both
        // variants in a single assertion).
        expect(
          eventJson.toLowerCase(),
          isNot(contains(alicePubkeyHex.toLowerCase())),
          reason: 'Sender identity pubkey must not appear in event JSON',
        );

        // ---- Assertion 6: ephemeral pubkey invariant ----
        // The outer event's "pubkey" field must be an ephemeral key that
        // differs from Alice's identity pubkey.  Extract it from the JSON
        // without a full JSON parse so the test stays dependency-free.
        final pubkeyMatch = RegExp(
          r'"pubkey"\s*:\s*"([0-9a-fA-F]{64})"',
        ).firstMatch(eventJson);
        expect(
          pubkeyMatch,
          isNotNull,
          reason: 'Event JSON must contain a 64-hex-char "pubkey" field',
        );
        final eventPubkey1 = pubkeyMatch!.group(1)!.toLowerCase();
        expect(
          eventPubkey1,
          isNot(equals(alicePubkeyHex.toLowerCase())),
          reason:
              'Outer event pubkey must be an ephemeral key, not the '
              "sender's identity pubkey",
        );

        // ---- Assertion 7: MLS group ID must NOT appear in event JSON ----
        // MIP-00 Rule 4: only the nostr_group_id (derived, public) is
        // published; the real MLS group ID must remain internal.
        expect(
          eventJson.toLowerCase(),
          isNot(contains(mlsGroupIdHex)),
          reason:
              'MIP-00 Rule 4: MLS group ID must not appear anywhere in '
              'event JSON (tags or content)',
        );

        // ---- Assertion 8: h-tag value EQUALS hex(nostrGroupId) ----
        // MIP-00 Rule 4: the h-tag IS the nostr_group_id — not just any
        // non-empty value.
        expect(
          eventJson,
          contains('"h","$nostrGroupIdHex"'),
          reason:
              'MIP-00 Rule 4: h-tag value must equal hex(nostrGroupId); '
              'expected to find ["h","$nostrGroupIdHex"] in event JSON',
        );

        // ---- Assertion 9: expiration tag within expected window ----
        // retentionSecs=3600 was passed; the expiration Unix timestamp must
        // fall in [nowSecs + 3500, nowSecs + 3700] to prove the parameter
        // is not silently dropped at the FFI boundary.
        final expirationMatch = RegExp(
          r'"expiration"\s*,\s*"(\d+)"',
        ).firstMatch(eventJson);
        expect(
          expirationMatch,
          isNotNull,
          reason:
              'kind 445 event must include an expiration tag when '
              'retentionSecs is provided',
        );
        final expirationTs = int.parse(expirationMatch!.group(1)!);
        expect(
          expirationTs,
          greaterThanOrEqualTo(nowSecs + 3500),
          reason:
              'Expiration timestamp must be at least nowSecs + 3500 '
              '(retentionSecs=3600 with 100 s tolerance)',
        );
        expect(
          expirationTs,
          lessThanOrEqualTo(nowSecs + 3700),
          reason:
              'Expiration timestamp must be at most nowSecs + 3700 '
              '(retentionSecs=3600 with 100 s tolerance)',
        );

        // ---- Assertion 10: positive ciphertext shape check ----
        // Extract the "content" field and verify it looks like base64 /
        // URL-safe base64 with at least 32 characters.  This catches a
        // regression where encryptLocation silently no-ops and the
        // plaintext-absence checks pass vacuously on empty content.
        final contentMatch = RegExp(
          r'"content"\s*:\s*"([^"]+)"',
        ).firstMatch(eventJson);
        expect(
          contentMatch,
          isNotNull,
          reason: 'Event JSON must contain a non-empty "content" field',
        );
        final ciphertext = contentMatch!.group(1)!;
        expect(
          ciphertext,
          matches(RegExp(r'^[A-Za-z0-9+/=_\-]{32,}$')),
          reason:
              'content must be base64 / URL-safe base64 with at least '
              '32 characters; got: "$ciphertext"',
        );

        // --------------------------------------------------------------
        // 11. Alice encrypts a SECOND location with different sentinel
        //     coordinates to verify ephemeral-key uniqueness per message.
        // --------------------------------------------------------------
        final encrypted2 = await aliceManager.encryptLocation(
          mlsGroupId: Uint8List.fromList(mlsGroupId),
          senderPubkeyHex: alicePubkeyHex,
          latitude: _sentinelLat2,
          longitude: _sentinelLon2,
          retentionSecs: BigInt.from(3600),
        );

        final eventJson2 = encrypted2.eventJson;

        // ---- Assertion 11a: second event also kind 445 ----
        expect(
          eventJson2,
          contains('"kind":445'),
          reason: 'Second outer event must also be kind 445',
        );

        // ---- Assertion 11b: distinct ephemeral pubkeys ----
        // MIP requires a fresh ephemeral key per message.
        final pubkeyMatch2 = RegExp(
          r'"pubkey"\s*:\s*"([0-9a-fA-F]{64})"',
        ).firstMatch(eventJson2);
        expect(
          pubkeyMatch2,
          isNotNull,
          reason: 'Second event JSON must contain a 64-hex-char "pubkey" field',
        );
        final eventPubkey2 = pubkeyMatch2!.group(1)!.toLowerCase();

        expect(
          eventPubkey2,
          isNot(equals(alicePubkeyHex.toLowerCase())),
          reason:
              'Second event outer pubkey must be an ephemeral key, not '
              "the sender's identity pubkey",
        );
        expect(
          eventPubkey2,
          isNot(equals(eventPubkey1)),
          reason:
              'Each kind 445 message must use a distinct ephemeral pubkey '
              '(MIP ephemeral-key-per-message requirement)',
        );

        // ---- Assertion 11c: no plaintext coordinates in second event ----
        for (final forbidden in _forbiddenLatSubstrings2) {
          expect(
            eventJson2,
            isNot(contains(forbidden)),
            reason:
                'Second encrypted event must not contain plaintext '
                'latitude substring "$forbidden"',
          );
        }
        for (final forbidden in _forbiddenLonSubstrings2) {
          expect(
            eventJson2,
            isNot(contains(forbidden)),
            reason:
                'Second encrypted event must not contain plaintext '
                'longitude substring "$forbidden"',
          );
        }

        // ---- Assertion 11d: sender pubkey not in second event JSON ----
        expect(
          eventJson2.toLowerCase(),
          isNot(contains(alicePubkeyHex.toLowerCase())),
          reason: 'Sender identity pubkey must not appear in second event JSON',
        );
      } finally {
        // ----------------------------------------------------------------
        // 12. Clean up temp directories regardless of test outcome.
        // ----------------------------------------------------------------
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {
          // Best-effort cleanup — ignore errors.
        }
        try {
          await bobDir.delete(recursive: true);
        } on Object catch (_) {
          // Best-effort cleanup — ignore errors.
        }
      }
    });
  });
}
