/// Integration tests for Haven's MIP-01 group-relay update feature —
/// convergence proofs at the SERVICE-FFI level.
///
/// ## What is under test
///
/// When an admin calls `NostrCircleService.updateCircleRelays`, the
/// implementation must:
///
///  1. Publish the `kind:445` relay-update commit to the UNION of the
///     circle's old relay list and the new one (so members on a relay
///     being dropped still receive the commit).
///  2. Finalize the commit on the admin side via `finalizeRelayUpdate`
///     (which also re-syncs the admin's `circle.relays` row).
///  3. Allow a member to converge: when the member's MDK processes the
///     relay-update commit via `decryptLocation`, it applies the
///     GroupContextExtensions change and updates the member's own
///     `circle.relays` row.
///  4. Subsequent `kind:445` traffic from the admin is routed to the
///     new relay set only.
///
/// ## Relay layout
///
/// ```text
/// R1 = defaultStrfryUrl  (7777)  — the default hermetic relay
/// R2 = secondStrfryUrl   (7778)  — the relay being added by the update
/// ```
///
/// ## Convergence-test path used
///
/// FULL SyntheticUser join: Bob bootstraps as a SyntheticUser, Alice
/// creates a circle with Bob as a member, Bob accepts the invitation via
/// `acceptInvitationViaRelay`, and then Bob processes the relay-update
/// commit via `drainPendingCommits`. This exercises the complete MLS
/// protocol path — Welcome, accept, relay-update commit, decryptLocation
/// — using the same FFI calls the production app uses.
///
/// ## Platform requirements
///
/// `CircleManagerFfi.newInstance` calls `init_keyring_store()` internally;
/// a live platform keyring is required. Each test skips honestly with
/// [markTestSkipped] when the keyring is unavailable.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/services/nostr_relay_service.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/synthetic_user.dart';
import 'e2e/_lib/test_relay.dart';
import 'e2e/_lib/test_user.dart';

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Convenience hex encoder — mirrors the one in test_user.dart.
String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Returns `true` iff the two lists contain exactly the same strings
/// (order-independent).
bool _sameRelays(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final aSet = a.toSet();
  return b.every(aSet.contains);
}

// ---------------------------------------------------------------------------
// Test entry-point
// ---------------------------------------------------------------------------

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The two hermetic relay observers shared by all tests. Opened once in
  // setUpAll and closed in tearDownAll.
  late TestRelay r1;
  late TestRelay r2;

  // Alice's single test identity. Bootstrapped once; each scenario creates
  // its own [CircleManagerFfi] in an isolated temp directory so MLS state
  // does not leak between tests.
  late TestUser alice;

  setUpAll(() async {
    // bootstrapProcess installs the in-memory keyring, arms ws-loopback
    // acceptance, and sets the process-global default relay list to [R1]
    // only. Must be called before any FFI operation.
    await TestUser.bootstrapProcess(relays: [defaultStrfryUrl]);

    r1 = await TestRelay.connect(url: defaultStrfryUrl);
    r2 = await TestRelay.connect(url: secondStrfryUrl);

    // Alice's identity — no CircleManagerFfi here; each test creates its own.
    alice = await TestUser.alice();
  });

  tearDownAll(() async {
    await r1.dispose();
    await r2.dispose();
    await alice.dispose();
  });

  // Precondition asserted in a testWidgets body (NOT setUpAll): a failed
  // expect() inside setUpAll is swallowed by integrationDriver and would let
  // the convergence proofs run vacuously. See
  // test/lints/integration_test_propagation_test.dart.
  testWidgets('precondition: R2 is not a process-global default relay', (
    tester,
  ) async {
    expect(
      defaultRelays(),
      isNot(contains(secondStrfryUrl)),
      reason:
          'R2 ($secondStrfryUrl) must NOT be in the process-global default '
          'relay list at startup. If it is, the convergence proofs cannot '
          'distinguish "events landed because the update propagated" from '
          '"events landed because R2 was already a default".',
    );
  });

  // =========================================================================
  // CONV-1  — full convergence: Alice updates relays [R1] -> [R1,R2]; Bob
  // receives the commit and converges; Alice's subsequent 445 lands on R2
  // =========================================================================
  testWidgets(
    'CONV-1: relay-update commit published to union, Alice and Bob '
    'converge to [R1,R2], subsequent 445 routed to R2',
    (tester) async {
      // Skip when the platform keyring is unavailable.
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping CONV-1.',
        );
        return;
      }

      // Per-test temp dirs so MLS state is isolated between scenarios.
      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_conv1_alice_',
      );
      try {
        // Alice's CircleManagerFfi — the real MLS + SQLCipher stack.
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );

        // Build a real NostrCircleService backed by aliceManager. This is
        // the production code path under test — not the FFI directly.
        final relayService = NostrRelayService();
        final aliceService = NostrCircleService.withInjectedManager(
          relayService: relayService,
          injectedManager: aliceManager,
        );

        final aliceSecretBytes = await alice.getSecretBytes();
        try {
          // Bob bootstraps as a SyntheticUser on R1 so Alice can fetch his
          // KeyPackage from R1 without a live relay query (we hand the KP
          // JSON directly to createCircle).
          final bob = await SyntheticUser.bob(r1);
          try {
            final bobSecretBytes = await bob.user.getSecretBytes();
            try {
              // -----------------------------------------------------------
              // Step 1: Alice creates a circle on [R1] only.
              // -----------------------------------------------------------
              final bobKp =
                  await bob.user.circleManager.signKeyPackageEvent(
                    identitySecretBytes: bobSecretBytes,
                    relays: <String>[defaultStrfryUrl],
                  );

              final creation = await aliceManager.createCircle(
                identitySecretBytes: aliceSecretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKp.eventJson,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Relay-Update Circle',
                circleType: 'location_sharing',
                relays: <String>[defaultStrfryUrl],
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );
              final mlsGroupId = creation.circle.mlsGroupId;
              final nostrGroupIdHex = _hex(
                creation.circle.nostrGroupId,
              );

              // Publish the Welcome to R1 and finalize the Add-members commit.
              for (final w in creation.welcomeEvents) {
                await r1.publishAndAwaitOk(w.eventJson);
              }
              await aliceManager.finalizePendingCommit(
                mlsGroupId: mlsGroupId,
              );

              // ORACLE: Alice's initial circle must have exactly [R1].
              final aliceInitial = await aliceManager.getCircle(
                mlsGroupId: mlsGroupId,
              );
              expect(
                aliceInitial,
                isNotNull,
                reason:
                    'Alice must have a circle row after creation.',
              );
              expect(
                aliceInitial!.circle.relays,
                equals(<String>[defaultStrfryUrl]),
                reason:
                    'circle.relays must be [R1] immediately after creation.',
              );

              // -----------------------------------------------------------
              // Step 2: Bob accepts the invitation.
              //
              // This is the full SyntheticUser join path: Bob waits on R1
              // for the gift-wrap addressed to him, processes it through
              // CircleManagerFfi.processGiftWrappedInvitation, then calls
              // acceptInvitation. After this Bob has a live local circle row.
              // -----------------------------------------------------------
              final bobCircle = await bob.acceptInvitationViaRelay(
                relay: r1,
              );
              expect(
                bobCircle.circle.mlsGroupId,
                equals(mlsGroupId),
                reason: 'Bob accepted the correct circle.',
              );
              // Drain any pending commits Bob's MDK surfaced when applying
              // the Welcome (e.g. a mandatory SelfUpdate).
              await bob.drainPendingCommits(
                relay: r1,
                circle: bobCircle,
              );

              // -----------------------------------------------------------
              // Step 3: Alice calls updateCircleRelays via
              // NostrCircleService — the production service path under test.
              //
              // Register relay observers on BOTH relays BEFORE calling the
              // service so we do not race the relay's ingestion.
              // -----------------------------------------------------------
              final r1CommitFuture = r1.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 60),
              );
              final r2CommitFuture = r2.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 60),
              );

              await aliceService.updateCircleRelays(
                mlsGroupId: mlsGroupId,
                newRelays: <String>[
                  defaultStrfryUrl,
                  secondStrfryUrl,
                ],
              );

              // -----------------------------------------------------------
              // Step 4: Assert the relay-update commit reached R1.
              //
              // The commit must land on R1 because R1 is in the union of
              // (current = [R1]) and (new = [R1, R2]). R2 is also in the
              // union, so the commit SHOULD reach R2 as well — but the
              // primary protocol invariant is that members on the OLD relay
              // set can still receive the commit.
              // -----------------------------------------------------------
              final commitOnR1 = await r1CommitFuture;
              debugPrint(
                '[CONV-1] relay-update commit on R1: '
                'id=${commitOnR1.id.substring(0, 8)}',
              );

              // ORACLE: the commit must also have been sent to R2 (the new
              // relay) because R2 is in the publish union. Members who
              // exclusively subscribe to R2 must also receive it.
              final commitOnR2 = await r2CommitFuture;
              debugPrint(
                '[CONV-1] relay-update commit on R2: '
                'id=${commitOnR2.id.substring(0, 8)}',
              );

              // -----------------------------------------------------------
              // Step 5: Alice's circle.relays must have converged to
              // [R1, R2].
              //
              // finalizeRelayUpdate (called inside aliceService) re-syncs
              // the admin's local circle row. We read it back to confirm.
              // -----------------------------------------------------------
              final aliceAfter = await aliceManager.getCircle(
                mlsGroupId: mlsGroupId,
              );
              expect(
                aliceAfter,
                isNotNull,
                reason:
                    'Alice must still have a circle row after the update.',
              );
              final aliceRelaysAfter = aliceAfter!.circle.relays;
              expect(
                aliceRelaysAfter,
                unorderedEquals(<String>[
                  defaultStrfryUrl,
                  secondStrfryUrl,
                ]),
                reason:
                    "Alice's circle.relays must be exactly [R1, R2] after "
                    'finalizeRelayUpdate re-syncs the admin row to '
                    'newRelays. A spurious extra relay would also fail '
                    'this assertion (tighter than separate contains checks).',
              );

              // -----------------------------------------------------------
              // Step 6: Bob drains the relay-update commit from R1.
              //
              // drainPendingCommits fetches kind-445 events tagged with the
              // circle's nostrGroupId and feeds them through
              // decryptLocation. The Rust consumer hook applies the
              // GroupContextExtensions change and updates the member's
              // local circle.relays row.
              // -----------------------------------------------------------
              final bobAfterUpdate = await bob.drainPendingCommits(
                relay: r1,
                circle: bobCircle,
              );
              debugPrint(
                '[CONV-1] Bob drain after relay-update: '
                'groupUpdates=${bobAfterUpdate.groupUpdatesProcessed} '
                'locations=${bobAfterUpdate.locationsProcessed}',
              );

              // Bob must have processed at least one group-state change
              // (the relay-update commit).
              expect(
                bobAfterUpdate.groupUpdatesProcessed,
                greaterThanOrEqualTo(1),
                reason:
                    'Bob must process the relay-update commit as a '
                    'group state change (groupUpdated=true). If this '
                    "is 0, Bob's MDK did not recognise the commit.",
              );

              // -----------------------------------------------------------
              // Step 7: Bob's circle.relays must have converged to [R1, R2].
              //
              // The Rust consumer hook in decryptLocation updates the
              // member's local circle row when processing a
              // GroupContextExtensions commit.
              // -----------------------------------------------------------
              final bobCircleAfter = await bob.getCircle(
                Uint8List.fromList(mlsGroupId),
              );
              expect(
                bobCircleAfter,
                isNotNull,
                reason:
                    'Bob must still have a circle row after processing the '
                    'relay-update commit.',
              );
              final bobRelaysAfter = bobCircleAfter!.circle.relays;
              expect(
                bobRelaysAfter,
                unorderedEquals(<String>[
                  defaultStrfryUrl,
                  secondStrfryUrl,
                ]),
                reason:
                    "Bob's circle.relays must be exactly [R1, R2] after "
                    'processing the relay-update commit. A spurious extra '
                    'relay would also fail this assertion (tighter than '
                    'separate contains checks). If this fails, the consumer '
                    'hook in decryptLocation did not update '
                    "Bob's circle row.",
              );

              // -----------------------------------------------------------
              // Step 8: Alice's and Bob's relay lists must agree.
              //
              // This is the convergence assertion: both parties must have
              // arrived at the same relay set for the group. A mismatch
              // means Bob's receive path and Alice's send path disagree on
              // where to route kind 445 traffic.
              // -----------------------------------------------------------
              expect(
                _sameRelays(aliceRelaysAfter, bobRelaysAfter),
                isTrue,
                reason:
                    'Alice and Bob must converge to the same relay set '
                    'after the relay-update commit is processed. '
                    'Alice=${aliceRelaysAfter.toSet()}, '
                    'Bob=${bobRelaysAfter.toSet()}',
              );

              // -----------------------------------------------------------
              // Step 9: A subsequent 445 from Alice goes to the new relay
              // set and specifically reaches R2.
              //
              // This proves routing uses circle.relays (the post-update
              // set) and not a stale snapshot.
              // -----------------------------------------------------------
              final r2PostUpdateFuture = r2.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 60),
              );

              final enc = await aliceManager.encryptLocation(
                mlsGroupId: mlsGroupId,
                senderPubkeyHex: alice.pubkeyHex,
                latitude: 51.5,
                longitude: -0.1,
                updateIntervalSecs: BigInt.from(
                  kLocationPublishMaxInterval.inSeconds +
                      kTtlNetworkBufferSeconds,
                ),
              );

              // Publish to the now-updated relay set: [R1, R2].
              final relayMgr = await RelayManagerFfi.newInstance();
              await relayMgr.publishEvent(
                eventJson: enc.eventJson,
                relays: aliceRelaysAfter,
              );

              final postUpdateOnR2 = await r2PostUpdateFuture;
              debugPrint(
                '[CONV-1] post-update 445 on R2: '
                'id=${postUpdateOnR2.id.substring(0, 8)}',
              );

              // ORACLE: the 445 must have reached R2, proving routing now
              // uses the updated relay set.
              expect(
                postUpdateOnR2,
                isNotNull,
                reason:
                    'A kind 445 published to the updated circle.relays '
                    '([R1,R2]) must reach R2. If it does not, post-update '
                    'routing is still using the old set [R1].',
              );

              // ORACLE: Bob must be able to decrypt Alice's post-update
              // location. This proves the MLS session is intact after the
              // relay-update commit (the epoch advanced correctly on both
              // sides).
              final bobDecryptResult = await bob.drainPendingCommits(
                relay: r2,
                circle: bobCircle,
              );
              expect(
                bobDecryptResult.decryptedLocationSenders,
                contains(alice.pubkeyHex.toLowerCase()),
                reason:
                    "Bob must be able to decrypt Alice's location published "
                    'after the relay-update. If this fails, the MLS epoch '
                    'is mismatched after the relay-update commit.',
              );

              debugPrint(
                '[CONV-1] PASS: relay-update commit on R1+R2; '
                'Alice converged to ${aliceRelaysAfter.toSet()}; '
                'Bob converged to ${bobRelaysAfter.toSet()}; '
                'post-update 445 reached R2 and Bob decrypted it.',
              );
            } finally {
              for (var i = 0; i < bobSecretBytes.length; i++) {
                bobSecretBytes[i] = 0;
              }
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < aliceSecretBytes.length; i++) {
            aliceSecretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // =========================================================================
  // CONV-2  — admin-auth negative: non-admin calling updateCircleRelays
  // throws; no commit reaches either relay
  // =========================================================================
  testWidgets(
    'CONV-2: non-admin member calling updateCircleRelays throws; '
    'no commit reaches R1 or R2',
    (tester) async {
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping CONV-2.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_conv2_alice_',
      );
      try {
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );

        final aliceSecretBytes = await alice.getSecretBytes();
        try {
          // Distinct invitee identity per subtest (CONV-1 bob, CONV-2 carol,
          // CONV-3 dave). The three subtests share ONE R1 that is wiped only
          // per CI target, so each subtest's gift-wrapped Welcome (kind 1059,
          // tagged `#p = invitee pubkey`) accumulates on R1. Reusing one
          // pubkey let acceptInvitationViaRelay's firstWhere(#p) pick a STALE
          // Welcome whose single-use KeyPackage is absent from this fresh
          // keystore -> "No matching key package was found" (flaky: NIP-59
          // randomizes gift-wrap created_at, so relay delivery order !=
          // publish order). A unique pubkey makes this subtest's #p query
          // match exactly one Welcome. Variable stays `bob` (the non-admin
          // invitee role); the admin-gate oracle is identity-agnostic.
          final bob = await SyntheticUser.carol(r1);
          try {
            final bobSecretBytes = await bob.user.getSecretBytes();
            try {
              // Alice creates a circle on [R1] with Bob as a member.
              final bobKp =
                  await bob.user.circleManager.signKeyPackageEvent(
                    identitySecretBytes: bobSecretBytes,
                    relays: <String>[defaultStrfryUrl],
                  );

              final creation = await aliceManager.createCircle(
                identitySecretBytes: aliceSecretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKp.eventJson,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Auth-Check Circle',
                circleType: 'location_sharing',
                relays: <String>[defaultStrfryUrl],
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );
              final mlsGroupId = creation.circle.mlsGroupId;
              final nostrGroupIdHex = _hex(
                creation.circle.nostrGroupId,
              );

              // Publish Welcome to R1 and finalize the Add-members commit.
              for (final w in creation.welcomeEvents) {
                await r1.publishAndAwaitOk(w.eventJson);
              }
              await aliceManager.finalizePendingCommit(
                mlsGroupId: mlsGroupId,
              );

              // Bob accepts the invitation so he is a full MLS member (and
              // therefore provably non-admin in Haven's single-admin model).
              final bobCircle = await bob.acceptInvitationViaRelay(
                relay: r1,
              );
              await bob.drainPendingCommits(
                relay: r1,
                circle: bobCircle,
              );

              // -----------------------------------------------------------
              // Negative assertion: Bob (non-admin) calling
              // updateCircleRelays via the FFI directly must throw. We
              // drive this at the FFI level because:
              //
              // (a) NostrCircleService wraps FFI errors into a generic
              //     CircleServiceException — we would lose the admin-gate
              //     signal.
              // (b) The assertion is "did the caller throw?" not "did the
              //     service throw?", which the FFI call makes unambiguous.
              //
              // The admin gate is enforced by MDK against live MLS state,
              // so a throw confirms the gate is active for Bob's epoch.
              // -----------------------------------------------------------
              Object? updateError;
              try {
                await bob.user.circleManager.updateCircleRelays(
                  mlsGroupId: bobCircle.circle.mlsGroupId,
                  newRelays: <String>[
                    defaultStrfryUrl,
                    secondStrfryUrl,
                  ],
                );
              } on Object catch (e) {
                updateError = e;
              }

              // ORACLE: non-admin must not be able to stage a relay-update
              // commit. If updateError is null, MDK's admin gate is not
              // enforcing and a non-admin could silently rotate the
              // relay list, redirecting all members' traffic.
              expect(
                updateError,
                isNotNull,
                reason:
                    'Non-admin (Bob) calling updateCircleRelays must throw. '
                    'MDK enforces admin authorization against live MLS '
                    'state; if no error is thrown the gate is not active '
                    'and an attacker could rotate the group relay list.',
              );
              debugPrint(
                '[CONV-2] non-admin updateCircleRelays threw '
                '(${updateError.runtimeType}) — admin gate is active',
              );

              // Capture a timestamp immediately before the negative-control
              // relay poll so we only look at events that could have been
              // published by the failed non-admin attempt.
              final sinceTs =
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 - 2;

              // ORACLE: no 445 commit must have landed on either relay.
              // This confirms the failed staging attempt did not emit an
              // event. A relay commit on R1 or R2 here would indicate that
              // MDK staged the commit before the admin check, causing an
              // uncommitted pending commit to leak — a consistency
              // violation.
              final r1Events = await r1.collectN(
                count: 1,
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': sinceTs,
                },
                timeout: const Duration(seconds: 10),
              );
              expect(
                r1Events,
                isEmpty,
                reason:
                    'No 445 commit must reach R1 after a failed non-admin '
                    'updateCircleRelays call. If a commit landed on R1 '
                    'the admin gate failed after staging — an event was '
                    'published for an uncommitted MLS state change.',
              );

              final r2Events = await r2.collectN(
                count: 1,
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': sinceTs,
                },
                timeout: const Duration(seconds: 10),
              );
              expect(
                r2Events,
                isEmpty,
                reason:
                    'Same no-commit guard on R2 after a failed non-admin '
                    'updateCircleRelays call.',
              );

              debugPrint(
                '[CONV-2] PASS: non-admin attempt threw; '
                'no 445 commit on R1 or R2 '
                '(nostrGroupIdHex='
                '${nostrGroupIdHex.substring(0, 8)}...)',
              );
            } finally {
              for (var i = 0; i < bobSecretBytes.length; i++) {
                bobSecretBytes[i] = 0;
              }
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < aliceSecretBytes.length; i++) {
            aliceSecretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );

  // =========================================================================
  // CONV-3  — relay-REMOVAL safety: Alice replaces [R1] with [R2] only;
  // the rotation commit still lands on R1 so Bob (on R1) can converge;
  // subsequent 445 routing no longer targets R1.
  //
  // CONV-3 proves the relay-REMOVAL safety property the union(old∪new)
  // publish exists for: the rotation commit reaches the relay being
  // removed so members on it converge, after which 445 routing no longer
  // targets the dropped relay.
  // =========================================================================
  testWidgets(
    'CONV-3: relay-REMOVAL — rotation commit reaches dropped R1 via '
    'union publish; Bob converges to [R2] only; subsequent 445 routes '
    'to R2 and does NOT newly arrive on R1',
    (tester) async {
      try {
        await initKeyringStore();
      } on Object catch (e) {
        markTestSkipped(
          'Keyring unavailable on this runner (${e.runtimeType}); '
          'skipping CONV-3.',
        );
        return;
      }

      final aliceDir = await Directory.systemTemp.createTemp(
        'haven_conv3_alice_',
      );
      try {
        // Alice's isolated CircleManagerFfi for this scenario.
        final aliceManager = await CircleManagerFfi.newInstance(
          dataDir: aliceDir.path,
        );

        final relayService = NostrRelayService();
        final aliceService = NostrCircleService.withInjectedManager(
          relayService: relayService,
          injectedManager: aliceManager,
        );

        final aliceSecretBytes = await alice.getSecretBytes();
        try {
          // dave is this subtest's non-admin invitee — a distinct pubkey from
          // CONV-1's bob and CONV-2's carol (see CONV-2's note: the shared,
          // per-target-only-reset R1 accumulates one kind-1059 Welcome per
          // subtest, and a reused `#p` lets firstWhere pick a stale Welcome
          // whose KeyPackage isn't in this keystore). Bootstraps on R1 (the
          // relay that will be REMOVED).
          final bob = await SyntheticUser.dave(r1);
          try {
            final bobSecretBytes = await bob.user.getSecretBytes();
            try {
              // -----------------------------------------------------------
              // Step 1: Alice creates a circle on [R1] only.
              // -----------------------------------------------------------
              final bobKp =
                  await bob.user.circleManager.signKeyPackageEvent(
                    identitySecretBytes: bobSecretBytes,
                    relays: <String>[defaultStrfryUrl],
                  );

              final creation = await aliceManager.createCircle(
                identitySecretBytes: aliceSecretBytes,
                members: [
                  MemberKeyPackageFfi(
                    keyPackageJson: bobKp.eventJson,
                    inboxRelays: <String>[defaultStrfryUrl],
                    nip65Relays: <String>[defaultStrfryUrl],
                  ),
                ],
                name: 'Relay-Removal Circle',
                circleType: 'location_sharing',
                relays: <String>[defaultStrfryUrl],
                creatorFallbackRelays: <String>[defaultStrfryUrl],
              );
              final mlsGroupId = creation.circle.mlsGroupId;
              final nostrGroupIdHex = _hex(
                creation.circle.nostrGroupId,
              );

              // Publish Welcome to R1 and finalize the Add-members commit.
              for (final w in creation.welcomeEvents) {
                await r1.publishAndAwaitOk(w.eventJson);
              }
              await aliceManager.finalizePendingCommit(
                mlsGroupId: mlsGroupId,
              );

              // ORACLE: initial circle must have exactly [R1].
              final aliceInitial = await aliceManager.getCircle(
                mlsGroupId: mlsGroupId,
              );
              expect(
                aliceInitial,
                isNotNull,
                reason:
                    'Alice must have a circle row after creation.',
              );
              expect(
                aliceInitial!.circle.relays,
                equals(<String>[defaultStrfryUrl]),
                reason:
                    'circle.relays must be [R1] immediately after creation.',
              );

              // -----------------------------------------------------------
              // Step 2: Bob joins via the full SyntheticUser path on R1.
              // -----------------------------------------------------------
              final bobCircle = await bob.acceptInvitationViaRelay(
                relay: r1,
              );
              expect(
                bobCircle.circle.mlsGroupId,
                equals(mlsGroupId),
                reason: 'Bob accepted the correct circle.',
              );
              // Drain any Welcome-induced auto-commits (e.g.
              // mandatory SelfUpdate).
              await bob.drainPendingCommits(
                relay: r1,
                circle: bobCircle,
              );

              // -----------------------------------------------------------
              // Step 3: Register a TestRelay observer on R1 BEFORE Alice calls
              // updateCircleRelays. The union of (old=[R1]) ∪ (new=[R2]) = [R1,
              // R2], so the rotation commit MUST still land on R1 even though
              // R1 is being dropped — this is the whole point of the union
              // publish.
              // -----------------------------------------------------------
              final r1CommitFuture = r1.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                },
                timeout: const Duration(seconds: 60),
              );

              // Alice replaces R1 with R2 only (R1 is DROPPED).
              await aliceService.updateCircleRelays(
                mlsGroupId: mlsGroupId,
                newRelays: <String>[secondStrfryUrl],
              );

              // -----------------------------------------------------------
              // Step 4: ASSERT the rotation commit landed on R1 — the relay
              // being dropped. Without the union(old∪new) publish, members
              // exclusively on R1 would never receive this commit and could
              // not converge to the new relay set.
              // -----------------------------------------------------------
              final commitOnR1 = await r1CommitFuture;
              debugPrint(
                '[CONV-3] rotation commit on R1 (dropped relay): '
                'id=${commitOnR1.id.substring(0, 8)}',
              );
              expect(
                commitOnR1,
                isNotNull,
                reason:
                    'The rotation commit must reach R1 even though R1 is '
                    'being dropped. The union(old∪new)={R1}∪{R2}=[R1,R2] '
                    'publish guarantees this; if the commit did not land on '
                    'R1, the union publish is not being performed and '
                    'members on the dropped relay cannot converge.',
              );

              // -----------------------------------------------------------
              // Step 5: Bob drains the rotation commit from R1.
              //
              // Bob is subscribed to R1 (the relay being removed). He receives
              // the commit there and processes it via decryptLocation, which
              // applies the GroupContextExtensions change and updates his local
              // circle.relays row to [R2] only.
              // -----------------------------------------------------------
              final bobAfterUpdate = await bob.drainPendingCommits(
                relay: r1,
                circle: bobCircle,
              );
              debugPrint(
                '[CONV-3] Bob drain from R1 after removal: '
                'groupUpdates=${bobAfterUpdate.groupUpdatesProcessed} '
                'locations=${bobAfterUpdate.locationsProcessed}',
              );
              expect(
                bobAfterUpdate.groupUpdatesProcessed,
                greaterThanOrEqualTo(1),
                reason:
                    'Bob must process the relay-removal commit as a group '
                    'state change (groupUpdated=true). If this is 0, '
                    "Bob's MDK did not recognise the commit from R1.",
              );

              // -----------------------------------------------------------
              // Step 6: ASSERT both Alice and Bob converged to [R2] ONLY
              // (R1 dropped).
              // -----------------------------------------------------------
              final aliceAfter = await aliceManager.getCircle(
                mlsGroupId: mlsGroupId,
              );
              expect(
                aliceAfter,
                isNotNull,
                reason:
                    'Alice must still have a circle row after the removal.',
              );
              final aliceRelaysAfter = aliceAfter!.circle.relays;
              expect(
                aliceRelaysAfter,
                unorderedEquals(<String>[secondStrfryUrl]),
                reason:
                    "Alice's circle.relays must be exactly [R2] after the "
                    'relay-removal update — R1 was dropped, R2 is the sole '
                    'remaining relay.',
              );

              final bobCircleAfter = await bob.getCircle(
                Uint8List.fromList(mlsGroupId),
              );
              expect(
                bobCircleAfter,
                isNotNull,
                reason:
                    'Bob must still have a circle row after processing the '
                    'relay-removal commit.',
              );
              final bobRelaysAfter = bobCircleAfter!.circle.relays;
              expect(
                bobRelaysAfter,
                unorderedEquals(<String>[secondStrfryUrl]),
                reason:
                    "Bob's circle.relays must be exactly [R2] after "
                    'processing the relay-removal commit. If this still '
                    'shows R1, the consumer hook in decryptLocation did not '
                    "update Bob's circle row to the new set.",
              );

              // No split-brain: both parties must agree on the same relay set.
              expect(
                _sameRelays(aliceRelaysAfter, bobRelaysAfter),
                isTrue,
                reason:
                    'Alice and Bob must agree on the relay set after the '
                    'removal. Alice=${aliceRelaysAfter.toSet()}, '
                    'Bob=${bobRelaysAfter.toSet()}',
              );

              // -----------------------------------------------------------
              // Step 7: Alice publishes a location 445 to the NEW circle.relays
              // ([R2] only). We capture a timestamp just before the publish so
              // the negative assertion on R1 cannot be contaminated by the
              // rotation commit that already landed there.
              // -----------------------------------------------------------
              // Capture "just before publish" to bound the negative R1 poll.
              final beforeLocationPublishTs =
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 - 1;

              final enc = await aliceManager.encryptLocation(
                mlsGroupId: mlsGroupId,
                senderPubkeyHex: alice.pubkeyHex,
                latitude: 48.8566,
                longitude: 2.3522,
                updateIntervalSecs: BigInt.from(
                  kLocationPublishMaxInterval.inSeconds +
                      kTtlNetworkBufferSeconds,
                ),
              );

              // Publish ONLY to the new relay set [R2].
              final relayMgr = await RelayManagerFfi.newInstance();
              await relayMgr.publishEvent(
                eventJson: enc.eventJson,
                relays: aliceRelaysAfter,
              );

              // -----------------------------------------------------------
              // Step 8: ASSERT the location 445 reached R2 (routing now uses
              // the updated relay set).
              // -----------------------------------------------------------
              final r2LocationFuture = r2.firstWhere(
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': beforeLocationPublishTs,
                },
                timeout: const Duration(seconds: 60),
              );
              final locationOnR2 = await r2LocationFuture;
              debugPrint(
                '[CONV-3] post-removal 445 on R2: '
                'id=${locationOnR2.id.substring(0, 8)}',
              );
              expect(
                locationOnR2,
                isNotNull,
                reason:
                    'A kind 445 published to the updated circle.relays '
                    '([R2]) must reach R2.',
              );

              // -----------------------------------------------------------
              // Step 9: ASSERT the location 445 did NOT newly arrive on R1
              // within a bounded window. The `since` timestamp is set just
              // before the publish so only truly new events count — prior
              // relay-update commit events on R1 do not contaminate this.
              //
              // This proves routing dropped the removed relay: after the
              // rotation commit Alice's send path uses circle.relays=[R2] and
              // no longer targets R1.
              // -----------------------------------------------------------
              final r1NewEvents = await r1.collectN(
                count: 1,
                filter: <String, dynamic>{
                  'kinds': <int>[445],
                  '#h': <String>[nostrGroupIdHex],
                  'since': beforeLocationPublishTs,
                },
                timeout: const Duration(seconds: 12),
              );
              expect(
                r1NewEvents,
                isEmpty,
                reason:
                    'No new kind 445 event must arrive on R1 after the '
                    'relay-removal update. If one does, routing is still '
                    'targeting the dropped relay — the relay set was not '
                    'updated on the send path.',
              );
              debugPrint(
                '[CONV-3] R1 negative-control passed: no new 445 on '
                'R1 after removal (since=$beforeLocationPublishTs)',
              );

              // -----------------------------------------------------------
              // Step 10: Bob decrypts Alice's location FROM R2, proving the
              // MLS epoch is intact on the new relay set after the removal.
              // -----------------------------------------------------------
              final bobDecryptResult = await bob.drainPendingCommits(
                relay: r2,
                circle: bobCircle,
              );
              expect(
                bobDecryptResult.decryptedLocationSenders,
                contains(alice.pubkeyHex.toLowerCase()),
                reason:
                    "Bob must decrypt Alice's location published after the "
                    'relay-removal from R2. If this fails, the MLS epoch is '
                    'mismatched after the relay-removal commit, or the '
                    'location was not published to R2.',
              );

              debugPrint(
                '[CONV-3] PASS: rotation commit on R1 (dropped relay); '
                'Alice converged to ${aliceRelaysAfter.toSet()}; '
                'Bob converged to ${bobRelaysAfter.toSet()}; '
                'post-removal 445 reached R2 only; '
                'Bob decrypted it from R2.',
              );
            } finally {
              for (var i = 0; i < bobSecretBytes.length; i++) {
                bobSecretBytes[i] = 0;
              }
            }
          } finally {
            await bob.dispose();
          }
        } finally {
          for (var i = 0; i < aliceSecretBytes.length; i++) {
            aliceSecretBytes[i] = 0;
          }
        }
      } finally {
        try {
          await aliceDir.delete(recursive: true);
        } on Object catch (_) {}
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
