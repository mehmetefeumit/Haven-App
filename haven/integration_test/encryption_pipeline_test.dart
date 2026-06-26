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
/// - Round-trip fidelity: Bob decrypts Alice's message and recovers exact
///   sentinel lat/lon (catches silent no-op or precision-truncation bugs)
/// - Wrong-recipient isolation: a third party NOT in the group cannot
///   decrypt Alice's message (cross-group privacy)
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
/// If the keyring is unavailable the test is marked as skipped with a
/// descriptive message rather than failing or returning silently.
/// All other assertions are unconditional once the keyring is confirmed
/// to be available.
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
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

/// Synthetic relay URL stamped into MIP-00 KeyPackage and MIP-04 Welcome
/// events. The test runs in-process between two `CircleManagerFfi`
/// instances and never actually publishes; the URL is required only so
/// MDK's `validate_relays_tag` (`mdk-core/src/key_packages.rs`) accepts
/// the events — MIP-00 makes the Relays tag mandatory.
///
/// Resolved via `--dart-define=HAVEN_E2E_RELAY=…` for parity with the
/// Android E2E workflow's hermetic strfry URL; falls back to
/// `ws://localhost:7777` for local runs. Mirrors
/// `integration_test/e2e/_lib/test_relay.dart::defaultStrfryUrl`.
const String _testRelayUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY',
  defaultValue: 'ws://localhost:7777',
);

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

/// Maximum tolerable difference between a sentinel and decrypted coordinate.
///
/// IEEE-754 double round-trip through MLS payload serialization and FFI
/// conversion should be lossless, but 1e-5 (≈1 m at the equator) gives
/// one order-of-magnitude margin for any floating-point edge cases while
/// still being tight enough to catch a regression where the coordinate is
/// wrong by more than noise.
const double _coordTolerance = 1e-5;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // Install a hermetic in-memory keyring up front so the plaintext-absence
    // proof below runs UNCONDITIONALLY rather than skipping when a platform
    // Keystore is unavailable. init_keyring_store() and
    // use_in_memory_keyring_for_test() share one init guard, so the in-test
    // initKeyringStore() call then returns Ok immediately and its
    // markTestSkipped path is unreachable. The keyring backend only protects
    // the SQLCipher DB key — it is orthogonal to what this test proves
    // (no plaintext coordinates in the kind-445 event), so using the
    // in-memory store does not weaken the assertion. Mirrors the e2e lanes'
    // bootstrap (test_user.dart / synthetic_user.dart).
    await useInMemoryKeyringForTest();
  });

  group('Location encryption pipeline (FFI boundary)', () {
    // testWidgets (not bare test): only a testWidgets body's failure is
    // recorded in the integration binding's results map and can fail the
    // `flutter drive` build. A bare test() failure is swallowed by
    // integrationDriver (it never reaches the host) — which previously hid the
    // round-trip/isolation failures below. See test/lints/
    // integration_test_propagation_test.dart. The `tester` is unused: these
    // exercise the FFI directly and never pump a widget tree.
    testWidgets('kind 445 event JSON contains no plaintext coordinates and '
        'uses ephemeral pubkey', (tester) async {
      // ----------------------------------------------------------------
      // 1. Verify keyring availability — skip honestly if unavailable.
      //    CircleManagerFfi.newInstance calls init_keyring_store() and
      //    get_or_create_circle_db_key() internally; both require a live
      //    platform keyring backend.
      // ----------------------------------------------------------------
      try {
        await initKeyringStore();
      } on Object catch (e) {
        // Platform keyring not available (e.g., no D-Bus Secret Service
        // on this Linux runner, or Keychain not unlocked on iOS).
        // markTestSkipped surfaces an honest skip rather than a vacuous pass.
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping encryption pipeline test.',
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
        const testRelays = <String>[_testRelayUrl];

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
              inboxRelays: const [_testRelayUrl],
              nip65Relays: const [_testRelayUrl],
            ),
          ],
          name: 'Enc Pipeline Test Circle',
          circleType: 'location_sharing',
          relays: const [_testRelayUrl],
          creatorFallbackRelays: const [_testRelayUrl],
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
        //    Bob must accept before he can decryptLocation (FN-2).
        // --------------------------------------------------------------
        expect(
          creationResult.welcomeEvents,
          isNotEmpty,
          reason: 'createCircle must emit at least one Welcome event for Bob',
        );

        final welcomeJson = creationResult.welcomeEvents.first.eventJson;
        InvitationFfi? bobInvitation;

        try {
          bobInvitation = await bobManager.processGiftWrappedInvitation(
            identitySecretBytes: bobSecretBytes,
            giftWrapEventJson: welcomeJson,
          );
          // `null` means the wrapper was already processed on a prior
          // iteration of this test — safe to skip the accept.
          if (bobInvitation != null) {
            await bobManager.acceptInvitation(
              mlsGroupId: bobInvitation.mlsGroupId,
            );
          }
        } on Object catch (e) {
          // Invitation processing is best-effort for the opacity/shape
          // assertions. However FN-2 (decrypt round-trip) requires a
          // successfully-accepted Bob, so we note the failure here and
          // let the round-trip assertion surface it if it matters.
          debugPrint(
            '[encryption_pipeline_test] Bob invitation processing failed '
            '(non-critical for encryption assertion): ${e.runtimeType}',
          );
        }

        // Capture wall-clock seconds before the first encrypt call so the
        // expiration window assertion is anchored to roughly "now".
        final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

        // --------------------------------------------------------------
        // 8. Alice encrypts the sentinel location (first message).
        // --------------------------------------------------------------
        const aliceDisplayName = 'Alice Test';
        final encrypted = await aliceManager.encryptLocation(
          mlsGroupId: Uint8List.fromList(mlsGroupId),
          senderPubkeyHex: alicePubkeyHex,
          latitude: _sentinelLat,
          longitude: _sentinelLon,
          displayName: aliceDisplayName,
          updateIntervalSecs: BigInt.from(
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          ),
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
        //
        // Guard: this scan is only meaningful when the two IDs differ.
        // If they were equal, `isNot(contains(mlsGroupIdHex))` would
        // simultaneously fail on the nostrGroupIdHex (Assertion 8), making
        // both assertions vacuously consistent with a leak. The explicit
        // precondition below causes an immediate test failure if the Rust
        // layer accidentally returns the same bytes for both IDs.
        expect(
          mlsGroupIdHex,
          isNot(equals(nostrGroupIdHex)),
          reason:
              'group-id leak scan is only meaningful if the MLS group id '
              'and the nostr_group_id differ; equal values would make the '
              'scan vacuous and mask a potential id-aliasing bug.',
        );
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
        // updateIntervalSecs=198 was passed; Rust samples the NIP-40
        // expiration tag uniformly in [interval, 2 * interval], so the
        // absolute expiration Unix timestamp must fall in
        // [nowSecs + 198, nowSecs + 396]. A 100 s tolerance covers the
        // gap between `nowSecs` and the actual encrypt-side `Utc::now()`.
        final updateIntervalSecs =
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds;
        final expirationMatch = RegExp(
          r'"expiration"\s*,\s*"(\d+)"',
        ).firstMatch(eventJson);
        expect(
          expirationMatch,
          isNotNull,
          reason: 'kind 445 event must include an expiration tag',
        );
        final expirationTs = int.parse(expirationMatch!.group(1)!);
        expect(
          expirationTs,
          greaterThanOrEqualTo(nowSecs + updateIntervalSecs - 100),
          reason:
              'Expiration timestamp must be at least nowSecs + interval - 100 '
              '(updateIntervalSecs=$updateIntervalSecs with 100 s tolerance)',
        );
        expect(
          expirationTs,
          lessThanOrEqualTo(nowSecs + 2 * updateIntervalSecs + 100),
          reason:
              'Expiration timestamp must be at most nowSecs + 2*interval + 100 '
              '(updateIntervalSecs=$updateIntervalSecs with 100 s tolerance)',
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
          updateIntervalSecs: BigInt.from(
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          ),
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

    // =========================================================================
    // FN-2: Full encrypt → decrypt round-trip.
    //
    // After Alice encrypts a location, Bob decrypts it and the recovered
    // coordinates must match the sentinels within 1e-5. A wrong-recipient
    // (Carol, a third identity not in the group) must receive null from
    // decryptLocation, proving cross-group isolation.
    // =========================================================================
    testWidgets("Bob can decrypt Alice's location and wrong recipient gets "
        'null (encrypt→decrypt round-trip + cross-group isolation)', (
      tester,
    ) async {
      // ------------------------------------------------------------------
      // Skip honestly if keyring unavailable — same pattern as above.
      // ------------------------------------------------------------------
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping round-trip decrypt test.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_rtrip_alice_',
      );
      final bobDir = await Directory.systemTemp.createTemp('haven_rtrip_bob_');
      final carolDir = await Directory.systemTemp.createTemp(
        'haven_rtrip_carol_',
      );

      try {
        // ----------------------------------------------------------------
        // Set up three identities: Alice + Bob in the same MLS group,
        // Carol is a complete outsider.
        // ----------------------------------------------------------------
        final aliceIdManager = await NostrIdentityManager.newInstance();
        await aliceIdManager.createIdentity();
        final aliceSecretBytes = await aliceIdManager.getSecretBytes();
        final alicePubkeyHex = aliceIdManager.pubkeyHex();

        final bobIdManager = await NostrIdentityManager.newInstance();
        await bobIdManager.createIdentity();
        final bobSecretBytes = await bobIdManager.getSecretBytes();

        // Carol is a completely independent identity — never added to the
        // Alice-Bob circle.
        final carolIdManager = await NostrIdentityManager.newInstance();
        await carolIdManager.createIdentity();

        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );
        final bobManager = await CircleManagerFfi.newInstance(
          dataDir: bobDir.path,
        );
        // Carol's manager has its own separate circle database and MLS
        // state — she is never invited to Alice's group.
        final carolManager = await CircleManagerFfi.newInstance(
          dataDir: carolDir.path,
        );

        const testRelays = <String>[_testRelayUrl];

        // ----------------------------------------------------------------
        // Bob signs a key package so Alice can create the circle with him.
        // ----------------------------------------------------------------
        final bobKpResult = await bobManager.signKeyPackageEvent(
          identitySecretBytes: bobSecretBytes,
          relays: testRelays,
        );

        // ----------------------------------------------------------------
        // Alice creates the circle with Bob as the sole member.
        // ----------------------------------------------------------------
        const aliceDisplayName = 'Alice Round-trip';
        final creation = await aliceManager.createCircle(
          identitySecretBytes: aliceSecretBytes,
          members: [
            MemberKeyPackageFfi(
              keyPackageJson: bobKpResult.eventJson,
              inboxRelays: const [_testRelayUrl],
              nip65Relays: const [_testRelayUrl],
            ),
          ],
          name: 'Round-trip Test Circle',
          circleType: 'location_sharing',
          relays: const [_testRelayUrl],
          creatorFallbackRelays: const [_testRelayUrl],
        );

        final mlsGroupId = Uint8List.fromList(creation.circle.mlsGroupId);

        // Alice merges her pending commit before encrypting.
        await aliceManager.finalizePendingCommit(mlsGroupId: mlsGroupId);

        // ----------------------------------------------------------------
        // Bob processes the gift-wrap and accepts the invitation.
        // Both parties must share the same epoch for decryption to work.
        // ----------------------------------------------------------------
        expect(
          creation.welcomeEvents,
          isNotEmpty,
          reason: 'createCircle must emit at least one Welcome event for Bob',
        );

        final invitation = await bobManager.processGiftWrappedInvitation(
          identitySecretBytes: bobSecretBytes,
          giftWrapEventJson: creation.welcomeEvents.first.eventJson,
        );
        expect(
          invitation,
          isNotNull,
          reason:
              'Bob must receive a pending invitation from the gift-wrap; '
              'null means the gift-wrap was already processed, which is '
              'impossible for a freshly-created group in a fresh temp dir.',
        );
        await bobManager.acceptInvitation(mlsGroupId: invitation!.mlsGroupId);

        // ----------------------------------------------------------------
        // Alice encrypts a location with the sentinel coordinates.
        // ----------------------------------------------------------------
        final encrypted = await aliceManager.encryptLocation(
          mlsGroupId: mlsGroupId,
          senderPubkeyHex: alicePubkeyHex,
          latitude: _sentinelLat,
          longitude: _sentinelLon,
          displayName: aliceDisplayName,
          updateIntervalSecs: BigInt.from(
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          ),
        );

        // Sanity: the event is still opaque (no plaintext coords).
        for (final forbidden in _forbiddenLatSubstrings) {
          expect(
            encrypted.eventJson,
            isNot(contains(forbidden)),
            reason: 'Sanity: encrypted event must not contain lat "$forbidden"',
          );
        }

        // ----------------------------------------------------------------
        // FN-2 POSITIVE: Bob decrypts Alice's event.
        // This is the primary regression guard: if decryptLocation is a
        // no-op or the MLS group states diverged, the result is null and
        // the expect below fails, surfacing the bug.
        // ----------------------------------------------------------------
        final decryptResult = await bobManager.decryptLocation(
          eventJson: encrypted.eventJson,
        );

        expect(
          decryptResult,
          isNotNull,
          reason:
              "Bob must be able to decrypt Alice's location event. "
              "A null result means either Bob's acceptInvitation did not "
              "converge to Alice's epoch, or decryptLocation is a no-op — "
              'both are regressions in the MLS pipeline.',
        );

        // decryptResult is non-null here; access its location field.
        final loc = decryptResult!.location;
        expect(
          loc,
          isNotNull,
          reason:
              'decryptResult.location must be populated for an application '
              'message; a null location with groupUpdated=true would mean '
              "Alice's encrypt was misrouted as a commit.",
        );

        // ---- Latitude round-trip ----
        expect(
          loc!.latitude,
          closeTo(_sentinelLat, _coordTolerance),
          reason:
              'Decrypted latitude must equal the sentinel $_sentinelLat '
              'within $_coordTolerance. Got: ${loc.latitude}. '
              'A mismatch means the Rust serializer truncated precision or '
              'swapped lat/lon.',
        );

        // ---- Longitude round-trip ----
        expect(
          loc.longitude,
          closeTo(_sentinelLon, _coordTolerance),
          reason:
              'Decrypted longitude must equal the sentinel $_sentinelLon '
              'within $_coordTolerance. Got: ${loc.longitude}. '
              'A mismatch means the Rust serializer truncated precision or '
              'swapped lat/lon.',
        );

        // ---- Display name round-trip ----
        expect(
          loc.displayName,
          equals(aliceDisplayName),
          reason:
              'Decrypted display name must equal "$aliceDisplayName". '
              'A mismatch or null means the display name field is not '
              'being carried through the MLS payload.',
        );

        // ---- Sender pubkey round-trip ----
        // The decrypted sender pubkey must equal Alice's identity pubkey
        // (the Rust layer embeds it in the inner kind-9 payload).
        expect(
          loc.senderPubkey.toLowerCase(),
          equals(alicePubkeyHex.toLowerCase()),
          reason:
              "Decrypted senderPubkey must equal Alice's identity pubkey. "
              'A mismatch means the Rust inner-payload serializer is not '
              'embedding the sender identity correctly.',
        );

        // ----------------------------------------------------------------
        // FN-2 NEGATIVE: Carol (outside the group) must NOT decrypt.
        //
        // Carol's CircleManagerFfi has no knowledge of the Alice-Bob group:
        // no MLS state, no circle row. decryptLocation on her instance
        // must return null — it cannot process a message for a group it
        // has never joined. If it returns a non-null value that is a
        // cross-group key-isolation regression.
        // ----------------------------------------------------------------
        // Carol's manager has no MLS state for Alice's group, so MDK fails
        // closed. It may do so two ways, BOTH of which uphold isolation:
        //   * return null (no group / unprocessable), or
        //   * throw an MLS error (e.g. "group not found") — `process_message`
        //     propagates as Err for an unknown group (manager.rs:2272), which
        //     the raw FFI surfaces as a thrown exception. The production
        //     service layer already catches this (nostr_circle_service.dart
        //     decryptLocation try/catch); the FN-2 callers swallow it and move
        //     on (location_sharing_service.dart). A throw is therefore an
        //     ACCEPTABLE isolation outcome — it yields no plaintext.
        // The load-bearing invariant is the same either way: Carol recovers NO
        // plaintext location. We assert exactly that, so a real regression — a
        // non-null *location* for a non-member — still fails loudly.
        DecryptResultFfi? carolResult;
        try {
          carolResult = await carolManager.decryptLocation(
            eventJson: encrypted.eventJson,
          );
        } on Object catch (e) {
          debugPrint(
            '[encryption_pipeline_test] Carol decrypt failed closed '
            '(isolation upheld): ${e.runtimeType}',
          );
        }

        expect(
          carolResult?.location,
          isNull,
          reason:
              "Carol (not a member of Alice's group) must NOT recover a "
              'plaintext location from decryptLocation. A non-null location '
              'here is a critical cross-group key-isolation failure: it means '
              'MLS keys are not properly scoped to group membership.',
        );

        debugPrint(
          '[encryption_pipeline_test] Round-trip OK — '
          'displayName=${loc.displayName}, '
          'carolResult=null (isolation confirmed)',
        );
      } finally {
        for (final dir in [aliceDir, bobDir, carolDir]) {
          try {
            await dir.delete(recursive: true);
          } on Object catch (_) {
            // Best-effort cleanup.
          }
        }
      }
    });
  });
}
