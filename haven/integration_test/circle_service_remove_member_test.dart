/// Integration tests for [NostrCircleService.removeMember].
///
/// ## Test 1 — fail-closed guard
///
/// `NostrCircleService.removeMember` sends a kind-445 RemoveMember commit
/// through the fanout driver, to the circle's own relays and nowhere else.
/// Falling back to `DEFAULT_RELAYS` for a circle whose relay list is lost
/// would leak the commit (and the `nostr_group_id` h-tag) to relays with no
/// other reason to know the group exists: a relay-level group-membership
/// disclosure. The contract is: **fail closed — never broadcast to a
/// dubious relay set.** Through the driver, a removal in a circle this device
/// does not hold is not made, and the driver's publish pool dials nothing.
/// That a commit's targets are the circle's own list is Rust's
/// (`haven-core/tests/foreign_routing_entry_e2e.rs`
/// `a_circle_whose_every_routing_entry_is_refused_has_no_relay`).
///
/// ## Test 2 — real removal happy path (FN-3)
///
/// Creates a genuine two-party MLS circle (Alice + Bob), then Alice removes
/// Bob through the fanout driver (`removeMembersDriven`). Asserts:
/// 1. `getCircle().members.length` drops by one.
/// 2. Bob can no longer take in a freshly sealed message (forward
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/circle_service.dart';
import 'package:haven/src/services/identity_service.dart';
import 'package:haven/src/services/location_sharing_service.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:haven/src/services/relay_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:haven/src/utils/log_alias.dart' show magnitudeBucket;
import 'package:haven/src/widgets/circles/circles_bottom_sheet.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/app_lifecycle.dart';
import 'e2e/_lib/circle_creation.dart'
    show createCircleDelivered, joinDeliveredWelcome;
import 'e2e/_lib/driven_location.dart';
import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

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
  @override
  Future<CatchupResult> runCatchup({
    required CircleManagerFfi circle,
    required String ownPubkeyHex,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<CatchupResult> runRefusedRefetch({
    required CircleManagerFfi circle,
    int maxDurationSecs = 20,
  }) async => const CatchupResult.empty();

  @override
  Future<KeyPackageMaintenanceOutcome> maintainKeyPackage({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const KeyPackageMaintenanceHealthy(
    canonicalOnRelays: 1,
    respondersProbed: 1,
  );

  @override
  Future<RelayListMaintenanceResult> maintainRelayList({
    required CircleManagerFfi circle,
    required List<int> identitySecretBytes,
  }) async => const RelayListMaintenanceResult.failed();

  @override
  Future<SubscriptionHealthResult> maintainSubscriptionHealth({
    required bool foreground,
  }) async => const SubscriptionHealthResult.empty();

  /// When true, [publishEvent] answers as a relay that ACCEPTED the event.
  ///
  /// Off by default so the fail-closed test still proves "no relay traffic
  /// was attempted"; the UI-driven removal below turns it on, because
  /// publish-before-apply (Rule 13) will not confirm a commit that no relay
  /// acked, and a removal that never confirms proves nothing about the UI
  /// that asked for it.
  bool ackPublishes = false;

  final List<({String eventJson, List<String> relays})> publishEventCalls = [];

  @override
  Future<PublishResult> publishEvent({
    required String eventJson,
    required List<String> relays,
  }) async {
    publishEventCalls.add((eventJson: eventJson, relays: List.of(relays)));
    return PublishResult(
      eventId: '',
      acceptedBy: ackPublishes ? List.of(relays) : const [],
      rejectedBy: const [],
      failed: const [],
    );
  }

  @override
  Future<List<String>> fetchNip65Relays(String pubkey) =>
      throw UnimplementedError();

  @override
  Future<KeyPackageData?> fetchKeyPackage(
    String pubkey, {
    List<int>? mlsGroupId,
  }) => throw UnimplementedError();

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
  }) => throw UnimplementedError();

  @override
  Future<List<String>> fetchGroupMessages({
    required List<int> nostrGroupId,
    required List<String> relays,
    DateTime? since,
    int? limit,
  }) => throw UnimplementedError();

  @override
  Future<List<OwnRelayPresenceFfi>> checkOwnReachability({
    required String ownPubkey,
  }) => throw UnimplementedError();

  @override
  Future<void> disconnectRelay(String url) => throw UnimplementedError();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Every test after the first starts with the lifecycle unset, and the
  // service asks for a removal in the foreground only when it reads `resumed`.
  resumeAppBeforeEachTest();

  setUpAll(() async {
    // Full hermetic process bootstrap, shared with the e2e lanes
    // (test_user.dart): Rust bridge init, in-memory keyring, the debug-only
    // loopback-`ws://` opt-in, and the default-relay override pointing every
    // relay resolution — including the discovery (lookup) plane — at the
    // local strfry. Dark Matter made both mandatory here: `addUserRelay`
    // (the NIP-65 seeding step before `maintainKeyPackage`) rejects a plain
    // `ws://` URL with "Use wss:// for security" unless the opt-in is armed,
    // and `fetchMemberKeypackage`'s discovery-plane fallback would consult the
    // PUBLIC indexers (non-hermetic) without the override. The override also
    // sharpens the fail-closed proof below: if removeMember ever regressed
    // into falling back to DEFAULT_RELAYS, it would now reach a LIVE local
    // relay and succeed — failing the test loudly instead of vacuously.
    //
    // The in-memory keyring means the forward-secrecy proof below runs
    // UNCONDITIONALLY rather than skipping when a platform Keystore is
    // unavailable. init_keyring_store() and use_in_memory_keyring_for_test()
    // share one init guard, so the in-test initKeyringStore() call returns Ok
    // immediately and its markTestSkipped path is unreachable. The keyring
    // backend only protects the SQLCipher DB key — it is orthogonal to what
    // this test proves (a removed member can no longer decrypt), so using
    // the in-memory store does not weaken the assertion.
    await TestUser.bootstrapProcess(relays: [_testRelayUrl]);
  });

  group('NostrCircleService.removeMember (fail-closed contract)', () {
    // =========================================================================
    // Test 1: the fail-closed guard, through the fanout driver. (It used to
    // run over a service with no driver, which threw before staging
    // anything, so it held nothing.)
    // =========================================================================
    // testWidgets (not bare test): only a testWidgets body's failure reaches
    // the integration binding's results map and can fail the `flutter drive`
    // build; a bare test() failure is swallowed by integrationDriver. See
    // test/lints/integration_test_propagation_test.dart. The `tester` is unused
    // (this drives the service/FFI directly, no widget tree).
    testWidgets(
      'a removal in a circle this device does not hold is not made, and the '
      "driver's pool dials nothing (no DEFAULT_RELAYS fallback)",
      (tester) async {
        installThrowTimeErrorLogging();
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
          // Dark Matter (DM-4): `CircleManagerFfi.newInstance` hard-requires
          // the identity secret bytes at construction time — give the
          // service a real (throwaway) identity to open with.
          final idManager = await NostrIdentityManager.newInstance();
          await idManager.createIdentity();

          final pool = await RelayManagerFfi.newInstance();
          final driver = NostrRelayService(openPool: () async => pool);
          final service = NostrCircleService(
            relayService: driver,
            dataDirectoryProvider: _FixedDataDirectoryProvider(dataDir.path),
            // The FFI getter itself, NOT a closure over one fetched buffer:
            // the service opens the manager through `withFreshSecret`, which
            // takes ownership of what the provider returns and scrubs it. A
            // closure handing back the SAME buffer every call yields 32 zero
            // bytes from the second call on.
            identitySecretBytesProvider: idManager.getSecretBytes,
          );

          await service.initialize();

          // A circle this device does not hold: no relay list to send to.
          final missingMlsGroupId = List<int>.generate(32, (i) => i + 1);
          final memberPubkeyHex = 'aa' * 32;

          // ----------------------------------------------------------------
          // Assertion 1: the removal is not made — the generic exception
          // with fixed copy, or "not made" from a driver that refused it —
          // and never "applied".
          // ----------------------------------------------------------------
          ChangeDelivery? delivery;
          Object? thrown;
          try {
            delivery = await service.removeMember(
              mlsGroupId: missingMlsGroupId,
              memberPubkeyHex: memberPubkeyHex,
            );
          } on CircleServiceException catch (e) {
            thrown = e;
          }
          expect(
            thrown == null
                ? delivery
                : (thrown as CircleServiceException).message,
            anyOf(ChangeDelivery.rejected, 'Failed to remove member'),
          );

          // ----------------------------------------------------------------
          // Assertion 2 (the load-bearing one): the driver's publish pool
          // dialled no relay. A fallback to DEFAULT_RELAYS would have.
          // ----------------------------------------------------------------
          expect(
            await pool.getRelayStatus(),
            isEmpty,
            reason:
                'removeMember must NOT fall back to DEFAULT_RELAYS when the '
                'circle relay list is unavailable — this is a relay-level '
                'group-membership disclosure. See '
                'docs/LOCATION_SHARING_SECURITY_BACKLOG.md.',
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
    // testWidgets (not bare test) so a forward-secrecy regression actually
    // fails the `flutter drive` build instead of being swallowed by
    // integrationDriver. See test/lints/integration_test_propagation_test.dart.
    testWidgets('member count drops by one and removed member cannot decrypt a '
        'post-removal message (forward secrecy)', (tester) async {
      installThrowTimeErrorLogging();
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

        final bobIdManager = await NostrIdentityManager.newInstance();
        final bobIdentity = await bobIdManager.createIdentity();
        final bobSecretBytes = await bobIdManager.getSecretBytes();
        final bobPubkeyHex = bobIdManager.pubkeyHex();

        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
          identitySecretBytes: aliceSecretBytes,
        );
        final bobManager = await CircleManagerFfi.newInstance(
          dataDir: bobDir.path,
          identitySecretBytes: bobSecretBytes,
        );

        // ----------------------------------------------------------------
        // Bob publishes a KeyPackage so Alice can create the circle with
        // him, via the Dark Matter maintain-key-package path (the ONE
        // publish path). It probes/publishes to Bob's OWN NIP-65 relays,
        // so seed that list with the test relay first.
        // ----------------------------------------------------------------
        await bobManager.addUserRelay(
          url: _testRelayUrl,
          relayType: RelayTypeFfi.nip65,
        );
        final bobRelayManager = await RelayManagerFfi.newInstance();
        await bobRelayManager.maintainKeyPackage(
          circle: bobManager,
          identitySecretBytes: bobSecretBytes,
        );
        final bobKpJson = (await bobRelayManager.fetchMemberKeypackage(
          pubkey: bobPubkeyHex,
          circle: aliceManager,
        )).member?.keyPackageJson;
        expect(
          bobKpJson,
          isNotNull,
          reason: 'Bob must have published a discoverable KeyPackage',
        );

        // ----------------------------------------------------------------
        // Alice creates the circle with Bob as the only member.
        // This also creates the circle row in the SQLCipher DB, which
        // is what makes `_circleRelays` return a non-null list and allows
        // the real removeMembers FFI path to execute (bypasses the
        // fail-closed guard that the guard test exercises).
        // ----------------------------------------------------------------
        final creation = await createCircleDelivered(
          manager: aliceManager,
          relayManager: bobRelayManager,
          identitySecretBytes: aliceSecretBytes,
          members: [
            MemberKeyPackageFfi(
              keyPackageJson: bobKpJson!,
              authorNpub: bobIdentity.npub,
              inboxRelays: const [_testRelayUrl],
              nip65Relays: const [_testRelayUrl],
              nip65WriteRelays: const [_testRelayUrl],
            ),
          ],
          name: 'Remove Member Test Circle',
          circleType: 'location_sharing',
          relays: const [_testRelayUrl],
          scenario: 'remove',
        );

        final mlsGroupId = Uint8List.fromList(creation.circle.mlsGroupId);

        // ----------------------------------------------------------------
        // Bob takes his Welcome off the relay and accepts — both parties
        // must be at the same MLS epoch before Alice can encrypt/remove.
        // ----------------------------------------------------------------
        await joinDeliveredWelcome(
          relayManager: bobRelayManager,
          invitee: bobManager,
          inviteeSecretBytes: bobSecretBytes,
          inviteePubkeyHex: bobPubkeyHex,
          relays: const [_testRelayUrl],
          scenario: 'remove',
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
              'Pre-removal: Alice + Bob = 2 members. Got '
              '${magnitudeBucket(memberCountBefore)}. A mismatch means '
              'createCircle or acceptInvitation did not sync the member '
              'list correctly.',
        );

        // ----------------------------------------------------------------
        // Forward-secrecy BASELINE: prove Bob CAN decrypt an Alice
        // location while he is still a member. Without this, the
        // post-removal "cannot decrypt" assertion would pass vacuously
        // if Bob never had working decryption in the first place.
        // ----------------------------------------------------------------
        // Every seal, ingest and change below goes through the fanout
        // driver, as production does.
        final aliceRelayManager = await RelayManagerFfi.newInstance();
        final preRemoval = await sealLocationForTest(
          relay: aliceRelayManager,
          circle: aliceManager,
          mlsGroupId: mlsGroupId,
          latitude: 40.111222,
          longitude: -74.333444,
        );
        final bobPreRemovalResults = await ingestForTest(
          relay: bobRelayManager,
          circle: bobManager,
          eventJson: preRemoval.eventJson,
        );
        final bobPreRemovalLocation = bobPreRemovalResults
            .where((r) => r.kind == LocationMessageResultKindFfi.location)
            .firstOrNull
            ?.location;
        expect(
          bobPreRemovalLocation,
          isNotNull,
          reason:
              'Baseline: Bob (a current member) MUST decrypt an Alice '
              'location BEFORE removal, otherwise the post-removal '
              'forward-secrecy check below would be vacuous.',
        );
        expect(
          bobPreRemovalLocation!.latitude,
          closeTo(40.111222, 1e-5),
          reason: 'Baseline decrypt must recover the exact latitude.',
        );

        // ----------------------------------------------------------------
        // Alice removes Bob through the driver (below the service layer):
        // the commit is staged, sent to the circle's relay and applied only
        // on that relay's acknowledgement (publish-before-apply, Rule 13).
        // ----------------------------------------------------------------
        final removal = await aliceRelayManager.removeMembersDriven(
          circle: aliceManager,
          mlsGroupId: mlsGroupId,
          memberPubkeys: [bobPubkeyHex],
          foreground: true,
        );
        expect(
          removal.status,
          PublishStatusFfi.confirmed,
          reason: 'the removal must be acknowledged and applied before its '
              'forward secrecy is tested',
        );

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
              'After removing Bob, member count must drop by one. Got '
              '${magnitudeBucket(memberCountAfter)} (was '
              '${magnitudeBucket(memberCountBefore)}). A regression in '
              'finalizePendingCommit or removeMembers would leave the '
              'member count unchanged.',
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
        // message Alice seals AFTER the remove commit.
        //
        // Bob's MLS state is now stale (Alice advanced the epoch by
        // merging the remove commit). When Bob's driver takes in Alice's
        // new message, MDK must reject it
        // because the epoch or key material no longer matches.
        //
        // The remove evolution event must be fed to Bob's state first so
        // Bob's MLS machinery knows the epoch advanced. Without processing
        // the commit Bob would see a decryption error (wrong epoch); with
        // it he is explicitly removed and his group state is invalid.
        //
        // In either case, the critical invariant is: Bob gets null (or
        // an unprocessable result) from taking in Alice's post-
        // removal message — he must NOT recover the plaintext coordinates.
        // ----------------------------------------------------------------

        // Feed the removal commit into Bob's state from the relay, as the
        // production receive path delivers it. We don't assert on these
        // calls' return values — the important check is what happens when
        // Bob tries to decrypt *after* them.
        final onRelay = await bobRelayManager.fetchGroupMessages(
          nostrGroupId: creation.circle.nostrGroupId,
          relays: const [_testRelayUrl],
        );
        for (final eventJson in onRelay) {
          try {
            await ingestForTest(
              relay: bobRelayManager,
              circle: bobManager,
              eventJson: eventJson,
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
        }

        // Alice seals a fresh location at the new epoch.
        final postRemoval = await sealLocationForTest(
          relay: aliceRelayManager,
          circle: aliceManager,
          mlsGroupId: mlsGroupId,
          latitude: 55.123456,
          longitude: 12.654321,
        );

        // Bob attempts to decrypt Alice's post-removal message. Having merged
        // his own eviction above, Bob's group state is invalid, so MDK fails
        // closed — and may do so two ways, BOTH upholding forward secrecy:
        //   * return null (None / unprocessable at the stale epoch), or
        //   * throw an MLS error (e.g. "group ... evicted") —
        //     `process_message` propagates as Err once the group is evicted
        //     (manager.rs:2272), which the raw FFI surfaces as a throw. This
        //     mirrors the already-accepted throw when Bob processed the remove
        //     commit above, and production catches it
        //     (location_sharing_service.dart decrypt loop).
        // A throw is therefore an ACCEPTABLE forward-secrecy outcome — it
        // yields no plaintext.
        List<LocationMessageResultFfi> bobPostRemovalResults = const [];
        try {
          bobPostRemovalResults = await ingestForTest(
            relay: bobRelayManager,
            circle: bobManager,
            eventJson: postRemoval.eventJson,
          );
        } on Object catch (e) {
          debugPrint(
            '[remove_member_test] Bob post-removal decrypt failed closed '
            '(forward secrecy upheld): ${e.runtimeType}',
          );
        }

        // Extract the decrypted location in a single step so the
        // forward-secrecy assertion is unconditional — no branch can
        // silently pass a non-null plaintext location through.
        //
        // Acceptable outcomes for `recovered`:
        //   null  — the ingest threw (failed closed), so the result stays
        //           null (no group / evicted)
        //   null  — the engine returned no results, or a `location`-kind
        //           result had a null inner location (a commit/state event,
        //           not a location)
        //
        // The ONLY unacceptable outcome is a non-null Location, which would
        // mean Bob successfully decrypted Alice's plaintext coordinates after
        // being evicted — a critical forward-secrecy failure.
        final recovered = bobPostRemovalResults
            .where((r) => r.kind == LocationMessageResultKindFfi.location)
            .firstOrNull
            ?.location;
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
          'memberCountBefore=${magnitudeBucket(memberCountBefore)}, '
          'memberCountAfter=${magnitudeBucket(memberCountAfter)}, '
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

  // ==========================================================================
  // The UI half. Everything above proves the engine and the service; this
  // proves the thing between them and the user — that the member list an
  // admin actually looks at reaches `removeMember` with the right group and
  // the right pubkey, and that the roster it re-renders afterwards came back
  // from the real MLS state rather than from a hopeful local edit.
  //
  // The widget suite (test/widgets/circles/remove_member_test.dart) covers
  // the same flow against a mock; a mock cannot tell you that the admin gate
  // reads the same `isAdmin` the engine writes, which is the one fact that
  // decides whether this feature is offered at all.
  // ==========================================================================
  group('the member list drives a real removal', () {
    testWidgets('an admin taps Remove and the member leaves the MLS roster', (
      tester,
    ) async {
      installThrowTimeErrorLogging();

      final aliceDir = await Directory.systemTemp.createTemp('haven_ui_alice_');
      final bobDir = await Directory.systemTemp.createTemp('haven_ui_bob_');

      try {
        final aliceIdManager = await NostrIdentityManager.newInstance();
        await aliceIdManager.createIdentity();
        final aliceSecretBytes = await aliceIdManager.getSecretBytes();
        final alicePubkeyHex = aliceIdManager.pubkeyHex();

        final bobIdManager = await NostrIdentityManager.newInstance();
        final bobIdentity = await bobIdManager.createIdentity();
        final bobSecretBytes = await bobIdManager.getSecretBytes();
        final bobPubkeyHex = bobIdManager.pubkeyHex();

        // ONE session per MLS database (Security Rule 14): Alice's circle is
        // created through the service's OWN handle, never a second
        // CircleManagerFfi opened on the same directory.
        // The removal goes through the fanout driver: Rust publishes it to
        // the circle's relay and applies it only once that relay acked.
        final relayRecorder = _RecordingRelayService();
        final service = NostrCircleService(
          relayService: relayRecorder,
          changeDriver: NostrRelayService(),
          dataDirectoryProvider: _FixedDataDirectoryProvider(aliceDir.path),
          // The FFI getter, not a closure over `aliceSecretBytes`: the service
          // scrubs the buffer the provider hands it, and this test reuses
          // `aliceSecretBytes` for `createCircle` below.
          identitySecretBytesProvider: aliceIdManager.getSecretBytes,
        );
        await service.initialize();
        final aliceManager = await service.getCircleManagerFfi();

        final bobManager = await CircleManagerFfi.newInstance(
          dataDir: bobDir.path,
          identitySecretBytes: bobSecretBytes,
        );
        await bobManager.addUserRelay(
          url: _testRelayUrl,
          relayType: RelayTypeFfi.nip65,
        );
        final bobRelayManager = await RelayManagerFfi.newInstance();
        await bobRelayManager.maintainKeyPackage(
          circle: bobManager,
          identitySecretBytes: bobSecretBytes,
        );
        final bobKpJson = (await bobRelayManager.fetchMemberKeypackage(
          pubkey: bobPubkeyHex,
          circle: aliceManager,
        )).member?.keyPackageJson;
        expect(bobKpJson, isNotNull);

        await createCircleDelivered(
          manager: aliceManager,
          relayManager: bobRelayManager,
          identitySecretBytes: aliceSecretBytes,
          members: [
            MemberKeyPackageFfi(
              keyPackageJson: bobKpJson!,
              authorNpub: bobIdentity.npub,
              inboxRelays: const [_testRelayUrl],
              nip65Relays: const [_testRelayUrl],
              nip65WriteRelays: const [_testRelayUrl],
            ),
          ],
          name: 'UI Removal Circle',
          circleType: 'location_sharing',
          relays: const [_testRelayUrl],
          scenario: 'remove',
        );

        final circles = await service.getVisibleCircles();
        expect(circles, hasLength(1));
        final circle = circles.single;
        // Every roster check below is a bool: a failing matcher prints its
        // operands, and these are pubkeys (Security Rule 15).
        expect(
          circle.members.any(
            (m) => m.pubkey.toLowerCase() == bobPubkeyHex.toLowerCase(),
          ),
          isTrue,
          reason: 'the roster the UI renders must start with Bob in it',
        );
        expect(
          circle.members
              .firstWhere(
                (m) => m.pubkey.toLowerCase() == alicePubkeyHex.toLowerCase(),
              )
              .isAdmin,
          isTrue,
          reason: 'the admin gate the sheet applies reads this exact flag off '
              'the engine — if the creator is not marked admin here, the '
              'remove affordance is never offered to anyone',
        );

        final sheetController = DraggableScrollableController();
        addTearDown(sheetController.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              circleServiceProvider.overrideWithValue(service),
              locationSharingServiceProvider.overrideWithValue(
                LocationSharingService(
                  circleService: service,
                  relayService: relayRecorder,
                ),
              ),
              // NOT selectedCircleProvider itself: that provider derives
              // from circlesProvider, and a static override here would
              // freeze the roster at its pre-removal snapshot regardless of
              // what member_removal_provider.dart invalidates afterwards.
              // Only the selection (which circle) is fixed; the roster
              // must come from the same live derivation the real app uses.
              selectedCircleIdProvider.overrideWith((ref) => circle.mlsGroupId),
              memberLocationsProvider.overrideWith((_) async => const []),
              identityProvider.overrideWith(
                (_) async => Identity(
                  pubkeyHex: alicePubkeyHex,
                  npub: 'npub1alice',
                  createdAt: DateTime(2025),
                ),
              ),
              displayNameProvider.overrideWith((_) async => 'Alice'),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: Stack(
                  children: [
                    CirclesBottomSheet(
                      onExpansionChanged: (_) {},
                      controller: sheetController,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        sheetController.jumpTo(0.85);
        await tester.pumpAndSettle();

        final removeButton = find.byKey(
          WidgetKeys.memberRemoveButton(bobPubkeyHex),
        );
        expect(
          removeButton.evaluate().length,
          equals(1),
          reason: 'an admin looking at a co-member must be offered the '
              'removal — this is the wiring that did not exist before',
        );

        // The service reads the lifecycle when the confirm lands, and a
        // removal is asked for in the foreground only.
        expectAppResumed();
        await tester.tap(removeButton);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(WidgetKeys.memberRemoveConfirm));
        await tester.pumpAndSettle();

        // The engine is the authority, not the widget tree: re-read the
        // roster through the FFI rather than trusting the list to have
        // re-rendered for the right reason.
        final after = await aliceManager.getCircle(
          mlsGroupId: Uint8List.fromList(circle.mlsGroupId),
        );
        // Applied only once the relay acked it: the driver confirms nothing
        // unacked (publish-before-apply, Rule 13 — owned by
        // `haven-core/tests/security_rule_gates.rs`).
        expect(
          after!.members.any(
            (m) => m.pubkey.toLowerCase() == bobPubkeyHex.toLowerCase(),
          ),
          isFalse,
          reason: 'a tap on the row must have staged, published, acked and '
              'applied a real Remove commit',
        );

        // And the list the admin is looking at agrees.
        expect(
          find.byKey(WidgetKeys.memberTile(bobPubkeyHex)).evaluate().isEmpty,
          isTrue,
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
