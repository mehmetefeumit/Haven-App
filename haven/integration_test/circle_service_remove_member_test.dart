/// Integration tests for [NostrCircleService.removeMember].
///
/// ## Test 1 — fail-closed guard (original, preserved verbatim per FN-3 rules)
///
/// `NostrCircleService.removeMember` is the admin-side eviction path that
/// publishes a kind-445 RemoveMember commit to the circle's relays. The
/// production guard at `nostr_circle_service.dart:667` says:
///
/// ```dart
/// if (relays == null || relays.isEmpty) {
///   debugPrint('Circle relays unavailable — aborting remove');
///   throw const CircleServiceException('Failed to remove member');
/// }
/// ```
///
/// This guard is critical for **defence-in-depth** privacy: if we ever lost
/// the circle's relay list (storage corruption, unmigrated record, FFI
/// throw), falling back to `DEFAULT_RELAYS` would leak the kind-445 commit
/// (and therefore the `nostr_group_id` h-tag) to relays that have no other
/// reason to know this group exists. That is a relay-level group-membership
/// disclosure. The contract is: **fail closed — never broadcast to a
/// dubious relay set.**
///
/// ## Test 2 — real removal happy path (FN-3)
///
/// Creates a genuine two-party MLS circle (Alice + Bob), then Alice removes
/// Bob via the real `removeMembers` FFI call. Asserts:
/// 1. `getCircle().members.length` drops by one.
/// 2. Bob can no longer `decryptLocation` a freshly-encrypted message (forward
///    secrecy: after epoch advance the removed party's key material is stale).
///
/// Both tests exercise the real FFI boundary; the keyring must be available.
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` calls `init_keyring_store()` and
/// `get_or_create_circle_db_key()` internally; both require a live platform
/// keyring backend. If unavailable the test is marked as skipped via
/// [markTestSkipped] (honest skip, not vacuous green).
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:integration_test/integration_test.dart';

/// Synthetic relay URL embedded in MIP-00 KeyPackage and MIP-04 Welcome
/// events. Mirrors the constant used in `encryption_pipeline_test.dart`.
const String _testRelayUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY',
  defaultValue: 'ws://localhost:7777',
);

/// [DataDirectoryProvider] that returns a fixed path provided by the test.
class _FixedDataDirectoryProvider implements DataDirectoryProvider {
  _FixedDataDirectoryProvider(this._path);
  final String _path;

  @override
  Future<String> getDataDirectory() async => _path;
}

/// [RelayService] that records every publish-style call so the test can
/// assert NO relay traffic was attempted on the fail-closed path.
///
/// Read-side methods throw [UnimplementedError] — `removeMember` should
/// not exercise them.
class _RecordingRelayService implements RelayService {
  final List<({String eventJson, List<String> relays})> publishEventCalls = [];
  final List<({String eventJson, List<String> relays})>
  publishFireAndForgetCalls = [];
  final List<GiftWrappedWelcome> publishWelcomeCalls = [];

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishEventCalls.add((eventJson: eventJson, relays: List.of(relays)));
    return const PublishResult(
      eventId: '',
      acceptedBy: [],
      rejectedBy: [],
      failed: [],
    );
  }

  @override
  Future<void> publishEventFireAndForget({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishFireAndForgetCalls.add((
      eventJson: eventJson,
      relays: List.of(relays),
    ));
  }

  @override
  Future<PublishResult> publishWelcome({
    required GiftWrappedWelcome welcomeEvent,
  }) async {
    publishWelcomeCalls.add(welcomeEvent);
    return const PublishResult(
      eventId: '',
      acceptedBy: [],
      rejectedBy: [],
      failed: [],
    );
  }

  @override
  Future<List<String>> fetchKeyPackageRelays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<KeyPackageData?> fetchKeyPackage(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<List<String>> fetchGiftWraps({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) => throw UnimplementedError();

  @override
  Future<List<RelayGiftWrapFetch>> fetchGiftWrapsPerRelay({
    required String recipientPubkey,
    required List<String> relays,
    DateTime? since,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<RelayEventCheck> checkEventOnRelay({
    required String relayUrl,
    required String authorPubkey,
    required int eventKind,
  }) => throw UnimplementedError();

  @override
  Future<void> disconnectRelay(String url) => throw UnimplementedError();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // Install a hermetic in-memory keyring up front so the forward-secrecy
    // proof below runs UNCONDITIONALLY rather than skipping when a platform
    // Keystore is unavailable. init_keyring_store() and
    // use_in_memory_keyring_for_test() share one init guard, so the in-test
    // initKeyringStore() call then returns Ok immediately and its
    // markTestSkipped path is unreachable. The keyring backend only protects
    // the SQLCipher DB key — it is orthogonal to what this test proves (a
    // removed member can no longer decrypt), so using the in-memory store
    // does not weaken the assertion. Mirrors the e2e lanes' bootstrap
    // (test_user.dart / synthetic_user.dart).
    await useInMemoryKeyringForTest();
  });

  group('NostrCircleService.removeMember (fail-closed contract)', () {
    // =========================================================================
    // Test 1: original fail-closed guard — preserved verbatim (FN-3 rule).
    // =========================================================================
    test(
      'throws CircleServiceException and does not fall back to DEFAULT_RELAYS '
      'when the circle has no relays available',
      () async {
        // ----------------------------------------------------------------
        // Skip if platform keyring is unavailable — honest skip via
        // markTestSkipped (FN-5), not a silent return.
        // ----------------------------------------------------------------
        try {
          await initKeyringStore();
        } on Object catch (e) {
          markTestSkipped(
            'Keyring unavailable on this runner (${e.runtimeType}); '
            'skipping fail-closed guard test.',
          );
          return;
        }

        final dataDir = await Directory.systemTemp.createTemp(
          'haven_remove_member_failclosed_',
        );

        try {
          final relayRecorder = _RecordingRelayService();
          final service = NostrCircleService(
            relayService: relayRecorder,
            dataDirectoryProvider: _FixedDataDirectoryProvider(dataDir.path),
          );

          await service.initialize();

          // Fabricate a non-existent circle ID. `_circleRelays` calls
          // `manager.getCircle(...)` which returns null for any ID we did
          // NOT create — the empty/null guard then fires before any
          // FFI staging or relay publish.
          final missingMlsGroupId = List<int>.generate(32, (i) => i + 1);

          // Any 32-byte hex pubkey will do — we never reach the FFI staging
          // call where pubkey validity matters.
          final memberPubkeyHex = 'aa' * 32;

          // ----------------------------------------------------------------
          // Assertion 1: removeMember must throw the generic
          // CircleServiceException with the redacted message — no FFI
          // detail leakage in the user-facing string.
          // ----------------------------------------------------------------
          await expectLater(
            service.removeMember(
              mlsGroupId: missingMlsGroupId,
              memberPubkeyHex: memberPubkeyHex,
            ),
            throwsA(
              isA<CircleServiceException>().having(
                (e) => e.message,
                'message',
                'Failed to remove member',
              ),
            ),
          );

          // ----------------------------------------------------------------
          // Assertion 2 (the load-bearing one): no relay-publish was
          // attempted. If a regression let `removeMember` fall back to
          // DEFAULT_RELAYS, the recorder would have at least one entry.
          // Empty == fail-closed contract upheld.
          // ----------------------------------------------------------------
          expect(
            relayRecorder.publishEventCalls,
            isEmpty,
            reason:
                'removeMember must NOT fall back to DEFAULT_RELAYS when the '
                'circle relay list is unavailable. publishEvent was called '
                '${relayRecorder.publishEventCalls.length} time(s) — this is '
                'a relay-level group-membership disclosure. See '
                'docs/LOCATION_SHARING_SECURITY_BACKLOG.md.',
          );

          // Defence in depth: the fire-and-forget and welcome paths must
          // also stay untouched on this code path.
          expect(
            relayRecorder.publishFireAndForgetCalls,
            isEmpty,
            reason: 'removeMember must not use fire-and-forget publishing',
          );
          expect(
            relayRecorder.publishWelcomeCalls,
            isEmpty,
            reason:
                'removeMember (eviction) must not invoke welcome publishing',
          );
        } finally {
          // Best-effort cleanup of the temp data directory.
          try {
            await dataDir.delete(recursive: true);
          } on Object catch (_) {
            // Ignore cleanup failures — temp dirs get cleaned by the OS.
          }
        }
      },
    );
  });

  // ==========================================================================
  // FN-3: Real removal happy path.
  //
  // This is a SEPARATE group from the fail-closed guard above so that each
  // test's keyring-skip branch is independent.
  // ==========================================================================
  group('NostrCircleService.removeMember (real removal + forward secrecy)', () {
    test('member count drops by one and removed member cannot decrypt a '
        'post-removal message (forward secrecy)', () async {
      // ------------------------------------------------------------------
      // Skip honestly if keyring unavailable — same pattern (FN-5).
      // ------------------------------------------------------------------
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping real-removal forward-secrecy test.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_remove_alice_',
      );
      final bobDir = await Directory.systemTemp.createTemp('haven_remove_bob_');

      try {
        // ----------------------------------------------------------------
        // Two identities: Alice (admin/creator) and Bob (member).
        // ----------------------------------------------------------------
        final aliceIdManager = await NostrIdentityManager.newInstance();
        await aliceIdManager.createIdentity();
        final aliceSecretBytes = await aliceIdManager.getSecretBytes();
        final alicePubkeyHex = aliceIdManager.pubkeyHex();

        final bobIdManager = await NostrIdentityManager.newInstance();
        await bobIdManager.createIdentity();
        final bobSecretBytes = await bobIdManager.getSecretBytes();
        final bobPubkeyHex = bobIdManager.pubkeyHex();

        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );
        final bobManager = await CircleManagerFfi.newInstance(
          dataDir: bobDir.path,
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
        // Alice creates the circle with Bob as the only member.
        // This also creates the circle row in the SQLCipher DB, which
        // is what makes `_circleRelays` return a non-null list and allows
        // the real removeMembers FFI path to execute (bypasses the
        // fail-closed guard that the guard test exercises).
        // ----------------------------------------------------------------
        final creation = await aliceManager.createCircle(
          identitySecretBytes: aliceSecretBytes,
          members: [
            MemberKeyPackageFfi(
              keyPackageJson: bobKpResult.eventJson,
              inboxRelays: const [_testRelayUrl],
              nip65Relays: const [_testRelayUrl],
            ),
          ],
          name: 'Remove Member Test Circle',
          circleType: 'location_sharing',
          relays: const [_testRelayUrl],
          creatorFallbackRelays: const [_testRelayUrl],
        );

        final mlsGroupId = Uint8List.fromList(creation.circle.mlsGroupId);

        // Alice merges her pending commit (from adding Bob) before any
        // subsequent operations on the group.
        await aliceManager.finalizePendingCommit(mlsGroupId: mlsGroupId);

        // ----------------------------------------------------------------
        // Bob processes his welcome and accepts — both parties must be
        // at the same MLS epoch before Alice can encrypt/remove.
        // ----------------------------------------------------------------
        expect(
          creation.welcomeEvents,
          isNotEmpty,
          reason: 'createCircle must emit at least one Welcome event for Bob',
        );

        final bobInvitation = await bobManager.processGiftWrappedInvitation(
          identitySecretBytes: bobSecretBytes,
          giftWrapEventJson: creation.welcomeEvents.first.eventJson,
        );
        expect(
          bobInvitation,
          isNotNull,
          reason:
              'Bob must receive a pending invitation; null means the '
              'gift-wrap was already processed in a prior run, which '
              'cannot happen for a freshly-created temp dir.',
        );
        await bobManager.acceptInvitation(
          mlsGroupId: bobInvitation!.mlsGroupId,
        );

        // ----------------------------------------------------------------
        // Pre-removal member count: Alice + Bob = 2.
        // ----------------------------------------------------------------
        final circleBefore = await aliceManager.getCircle(
          mlsGroupId: mlsGroupId,
        );
        expect(
          circleBefore,
          isNotNull,
          reason: 'getCircle must return the circle Alice just created.',
        );
        final memberCountBefore = circleBefore!.members.length;
        expect(
          memberCountBefore,
          equals(2),
          reason:
              'Pre-removal: Alice + Bob = 2 members. Got $memberCountBefore. '
              'A mismatch means createCircle or acceptInvitation did not '
              'sync the member list correctly.',
        );

        // ----------------------------------------------------------------
        // Forward-secrecy BASELINE: prove Bob CAN decrypt an Alice
        // location while he is still a member. Without this, the
        // post-removal "cannot decrypt" assertion would pass vacuously
        // if Bob never had working decryption in the first place.
        // ----------------------------------------------------------------
        final preRemovalEncrypt = await aliceManager.encryptLocation(
          mlsGroupId: mlsGroupId,
          senderPubkeyHex: alicePubkeyHex,
          latitude: 40.111222,
          longitude: -74.333444,
          updateIntervalSecs: BigInt.from(
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          ),
        );
        final bobPreRemovalResult = await bobManager.decryptLocation(
          eventJson: preRemovalEncrypt.eventJson,
        );
        expect(
          bobPreRemovalResult?.location,
          isNotNull,
          reason:
              'Baseline: Bob (a current member) MUST decrypt an Alice '
              'location BEFORE removal, otherwise the post-removal '
              'forward-secrecy check below would be vacuous.',
        );
        expect(
          bobPreRemovalResult!.location!.latitude,
          closeTo(40.111222, 1e-5),
          reason: 'Baseline decrypt must recover the exact latitude.',
        );

        // ----------------------------------------------------------------
        // Alice removes Bob directly via the FFI (bypassing the service
        // layer so we test the core MDK path without relay publish).
        // This call stages a pending commit and returns an evolution event.
        // ----------------------------------------------------------------
        final removeResult = await aliceManager.removeMembers(
          mlsGroupId: mlsGroupId,
          memberPubkeys: [bobPubkeyHex],
        );

        // Merge the pending commit so Alice's MLS state advances and Bob
        // is no longer in her local group view.
        await aliceManager.finalizePendingCommit(mlsGroupId: mlsGroupId);

        // ----------------------------------------------------------------
        // FN-3 Assertion 1: member count dropped by one on Alice's side.
        // ----------------------------------------------------------------
        final circleAfter = await aliceManager.getCircle(
          mlsGroupId: mlsGroupId,
        );
        expect(
          circleAfter,
          isNotNull,
          reason: "getCircle must still return the circle after Bob's removal.",
        );
        final memberCountAfter = circleAfter!.members.length;
        expect(
          memberCountAfter,
          equals(memberCountBefore - 1),
          reason:
              'After removing Bob, member count must be '
              '${memberCountBefore - 1}. Got $memberCountAfter. '
              'A regression in finalizePendingCommit or removeMembers would '
              'leave the member count unchanged.',
        );

        // Alice must no longer see Bob in the member list.
        final bobStillPresent = circleAfter.members.any(
          (m) => m.pubkey.toLowerCase() == bobPubkeyHex.toLowerCase(),
        );
        expect(
          bobStillPresent,
          isFalse,
          reason:
              "Bob's pubkey must not appear in the member list after "
              'removal. If it does, the epoch advance did not flush the '
              'old member set.',
        );

        // ----------------------------------------------------------------
        // FN-3 Assertion 2: forward secrecy — Bob cannot decrypt a
        // message Alice encrypts AFTER the remove commit.
        //
        // Bob's MLS state is now stale (Alice advanced the epoch by
        // merging the remove commit). When Bob's CircleManagerFfi calls
        // decryptLocation on Alice's new message, MDK must reject it
        // because the epoch or key material no longer matches.
        //
        // The remove evolution event must be fed to Bob's state first so
        // Bob's MLS machinery knows the epoch advanced. Without processing
        // the commit Bob would see a decryption error (wrong epoch); with
        // it he is explicitly removed and his group state is invalid.
        //
        // In either case, the critical invariant is: Bob gets null (or
        // an unprocessable result) from decryptLocation on Alice's post-
        // removal message — he must NOT recover the plaintext coordinates.
        // ----------------------------------------------------------------

        // Feed the removal evolution event into Bob's state (this is
        // what the production relay layer would deliver to Bob).
        // We don't assert on this call's return value — the important
        // check is what happens when Bob tries to decrypt *after* it.
        try {
          await bobManager.decryptLocation(
            eventJson: removeResult.evolutionEventJson,
          );
        } on Object catch (e) {
          // If Bob's side rejects the commit event (e.g., MDK raises an
          // error for a remove that targets the processor itself), that
          // is also consistent with the forward-secrecy invariant.
          debugPrint(
            '[remove_member_test] Bob processed removal event with '
            'result: ${e.runtimeType} (acceptable)',
          );
        }

        // Alice encrypts a fresh location at the new epoch.
        final postRemovalEncrypt = await aliceManager.encryptLocation(
          mlsGroupId: mlsGroupId,
          senderPubkeyHex: alicePubkeyHex,
          latitude: 55.123456,
          longitude: 12.654321,
          updateIntervalSecs: BigInt.from(
            kLocationPublishMaxInterval.inSeconds + kTtlNetworkBufferSeconds,
          ),
        );

        // Bob attempts to decrypt Alice's post-removal message.
        // The result MUST be null (MDK cannot decrypt at the old epoch).
        // If it returns a non-null value with a location, Bob retained
        // access after being evicted — a forward-secrecy failure.
        final bobPostRemovalResult = await bobManager.decryptLocation(
          eventJson: postRemovalEncrypt.eventJson,
        );

        // Extract the decrypted location in a single step so the
        // forward-secrecy assertion is unconditional — no branch can
        // silently pass a non-null plaintext location through.
        //
        // Acceptable outcomes for `recovered`:
        //   null  — MDK returned None (no group / unprocessable after remove)
        //   null  — inner DecryptedLocationFfi had location == null
        //           (a commit/state event, not a plaintext location message)
        //
        // The ONLY unacceptable outcome is a non-null Location, which would
        // mean Bob successfully decrypted Alice's plaintext coordinates after
        // being evicted — a critical forward-secrecy failure.
        final recovered = bobPostRemovalResult?.location;
        expect(
          recovered,
          isNull,
          reason:
              'forward secrecy: evicted member must recover NO plaintext '
              'location post-removal. A non-null location here means Bob '
              'retained decryption capability after the epoch advance — '
              'critical forward-secrecy failure.',
        );

        debugPrint(
          '[remove_member_test] Forward secrecy OK — '
          'memberCountBefore=$memberCountBefore, '
          'memberCountAfter=$memberCountAfter, '
          'bobRecoveredLocation=false (confirmed null)',
        );
      } finally {
        for (final dir in [aliceDir, bobDir]) {
          try {
            await dir.delete(recursive: true);
          } on Object catch (_) {
            // Best-effort cleanup.
          }
        }
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
