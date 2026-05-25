/// FFI-level safety net for the "ghost admin" recovery path described in
/// `docs/ADMIN_LEAVE_GHOST_BUG.md`.
///
/// Two-party setup driven entirely through the Rust FFI (no UI). Alice
/// publishes a raw SelfRemove proposal that MDK's admin-gate ignores;
/// the test asserts Bob's `decryptLocation` surfaces the
/// `IgnoredProposal` reason via [DecryptResultFfi.ignoredReason] —
/// which is the FFI hook the production `LocationSharingService` reads
/// to drive the "Leaving…" badge. Then Bob exercises the admin
/// recovery path by calling `removeMembers` and the test asserts the
/// resulting RemoveMember commit is a structurally valid kind-445
/// evolution event ready for relay publication.
///
/// Acceptance hooks covered:
///   - Reverting the IgnoredProposal → `DecryptResultFfi.ignoredReason`
///     mapping (in `haven-core/src/nostr/mls/manager.rs`) makes the
///     first assertion fail.
///   - Reverting the `removeMembers` FFI publish path (in
///     `haven/rust_builder/src/api.rs`) or the underlying
///     `CircleManager::remove_members` makes the second assertion fail.
///
/// This test runs without a relay: events are passed directly between
/// the two `CircleManagerFfi` instances. The shape mirrors
/// `encryption_pipeline_test.dart` and
/// `circle_service_remove_member_test.dart`.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/rust/api.dart';
import 'package:haven/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

/// Sentinel seeds — deterministic, public test values. Mirror the
/// `aliceSeed` / `bobSeed` constants in
/// `integration_test/e2e/_lib/test_user.dart`.
final Uint8List _aliceSeed = Uint8List.fromList(List<int>.filled(32, 1));
final Uint8List _bobSeed = Uint8List.fromList(List<int>.filled(32, 2));

/// Synthetic relay URL embedded into MIP-00 KeyPackage and MIP-04 Welcome
/// events.
///
/// This is an FFI-level test: events are passed directly between two
/// `CircleManagerFfi` instances and nothing actually publishes to the
/// relay. The URL is required only so MDK's `validate_relays_tag`
/// (`mdk-core/src/key_packages.rs`) accepts the resulting events — MIP-00
/// makes the Relays tag mandatory.
///
/// Resolved via `--dart-define=HAVEN_E2E_RELAY=…` so the CI workflow's
/// hermetic strfry URL flows through to this test on the emulator; falls
/// back to `ws://localhost:7777` for local runs. The default mirrors
/// `integration_test/e2e/_lib/test_relay.dart::defaultStrfryUrl`; if the
/// env-var contract ever changes, update both sites and the workflow YAML.
const String _testRelayUrl = String.fromEnvironment(
  'HAVEN_E2E_RELAY',
  defaultValue: 'ws://localhost:7777',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
    // Hermetic in-memory keyring so the test doesn't need a platform
    // Keystore/Keychain. Mirrors the e2e scenarios' bootstrap path.
    await useInMemoryKeyringForTest();
  });

  group('Admin SelfRemove ghost recovery (FFI)', () {
    test(
      'MDK admin-gate surfaces IgnoredProposal via decryptLocation; '
      'remaining admin clears the ghost via removeMembers',
      () async {
        // ----------------------------------------------------------------
        // Per-test isolated data directories so a re-run can't pick up
        // SQLCipher state from a previous attempt.
        // ----------------------------------------------------------------
        final aliceDir = await Directory.systemTemp.createTemp(
          'ghost_admin_alice_',
        );
        final bobDir = await Directory.systemTemp.createTemp(
          'ghost_admin_bob_',
        );

        try {
          // --------------------------------------------------------------
          // Two identities loaded from sentinel seeds.
          // --------------------------------------------------------------
          final aliceIdent = await NostrIdentityManager.newInstance();
          final alicePub = await aliceIdent.loadFromBytes(
            secretBytes: _aliceSeed,
          );
          final aliceSecret = await aliceIdent.getSecretBytes();

          final bobIdent = await NostrIdentityManager.newInstance();
          final bobPub = await bobIdent.loadFromBytes(
            secretBytes: _bobSeed,
          );
          final bobSecret = await bobIdent.getSecretBytes();

          // --------------------------------------------------------------
          // Two CircleManagerFfi instances — one per party.
          // --------------------------------------------------------------
          final aliceCircle = await CircleManagerFfi.newInstance(
            dataDir: aliceDir.path,
          );
          final bobCircle = await CircleManagerFfi.newInstance(
            dataDir: bobDir.path,
          );

          // --------------------------------------------------------------
          // 1. Bob signs a KeyPackage so Alice can include him.
          // --------------------------------------------------------------
          final bobKp = await bobCircle.signKeyPackageEvent(
            identitySecretBytes: bobSecret,
            relays: const <String>[_testRelayUrl],
          );

          // --------------------------------------------------------------
          // 2. Alice creates the circle with Bob as the only member.
          //    Alice is the sole admin.
          // --------------------------------------------------------------
          final creation = await aliceCircle.createCircle(
            identitySecretBytes: aliceSecret,
            members: [
              MemberKeyPackageFfi(
                keyPackageJson: bobKp.eventJson,
                inboxRelays: const <String>[_testRelayUrl],
                nip65Relays: const <String>[_testRelayUrl],
              ),
            ],
            name: 'Ghost Admin Test',
            circleType: 'location_sharing',
            relays: const <String>[_testRelayUrl],
            creatorFallbackRelays: const <String>[_testRelayUrl],
          );
          final mlsGroupId = Uint8List.fromList(
            creation.circle.mlsGroupId,
          );

          // Alice must merge her own pending commit (from adding Bob)
          // before subsequent operations on the group.
          await aliceCircle.finalizePendingCommit(mlsGroupId: mlsGroupId);

          // --------------------------------------------------------------
          // 3. Bob processes the gift-wrap and accepts.
          // --------------------------------------------------------------
          expect(
            creation.welcomeEvents,
            isNotEmpty,
            reason: 'createCircle must emit a Welcome for Bob',
          );
          final invitation = await bobCircle.processGiftWrappedInvitation(
            identitySecretBytes: bobSecret,
            giftWrapEventJson: creation.welcomeEvents.first.eventJson,
          );
          expect(invitation, isNotNull);
          await bobCircle.acceptInvitation(
            mlsGroupId: invitation!.mlsGroupId,
          );

          // --------------------------------------------------------------
          // 4. Promote Bob to admin via proposeAdminHandoff. Bob needs to
          //    be admin so his later removeMembers call is authoritative.
          //    Both sides apply the commit.
          // --------------------------------------------------------------
          final handoff = await aliceCircle.proposeAdminHandoff(
            mlsGroupId: mlsGroupId,
            successorHex: bobPub.pubkeyHex,
          );
          await aliceCircle.finalizePendingCommit(mlsGroupId: mlsGroupId);
          final bobAppliedHandoff = await bobCircle.decryptLocation(
            eventJson: handoff.evolutionEventJson,
          );
          expect(
            bobAppliedHandoff,
            isNotNull,
            reason: 'Bob must process the handoff commit emitted by '
                'the existing admin (Alice).',
          );
          expect(
            bobAppliedHandoff!.groupUpdated,
            isTrue,
            reason: 'AdminHandoff is a group-state change; '
                'the joiner side must observe groupUpdated == true.',
          );

          // --------------------------------------------------------------
          // 5. Alice publishes a RAW SelfRemove proposal — bypassing the
          //    production LeavePlan ceremony (no self-demote). Alice is
          //    still admin in Bob's local group state (the handoff
          //    promoted Bob without demoting Alice), so MDK's admin-gate
          //    is guaranteed to fire on Bob's side.
          // --------------------------------------------------------------
          final aliceSelfRemove = await aliceCircle.proposeLeave(
            mlsGroupId: mlsGroupId,
          );

          // --------------------------------------------------------------
          // 6. Bob processes Alice's SelfRemove. ASSERTION ONE:
          //    DecryptResultFfi.ignoredReason must be populated — this
          //    is the hook the production LocationSharingService reads
          //    to drive the "Leaving…" badge.
          // --------------------------------------------------------------
          final bobProcessResult = await bobCircle.decryptLocation(
            eventJson: aliceSelfRemove.evolutionEventJson,
          );
          expect(
            bobProcessResult,
            isNotNull,
            reason: 'Bob must produce a DecryptResultFfi for the '
                'admin SelfRemove (not return null).',
          );
          expect(
            bobProcessResult!.ignoredReason,
            isNotNull,
            reason: 'MDK admin-gate must surface IgnoredProposal as '
                'DecryptResultFfi.ignoredReason. If this is null, the '
                'ghost admin bug is reintroduced: '
                'LocationSharingService loses the signal needed to '
                'flip pendingDepartureProvider.',
          );
          expect(
            bobProcessResult.ignoredMlsGroupId,
            isNotNull,
            reason: 'ignoredMlsGroupId must accompany ignoredReason '
                'so the UI can scope the badge to the correct circle.',
          );
          expect(
            Uint8List.fromList(bobProcessResult.ignoredMlsGroupId!),
            equals(mlsGroupId),
          );
          expect(
            bobProcessResult.groupUpdated,
            isFalse,
            reason: 'No local group-state change happened — '
                'IgnoredProposal must not signal a group update.',
          );
          expect(
            bobProcessResult.evolutionEventJson,
            isNull,
            reason: 'No commit was produced; '
                'evolutionEventJson must remain null.',
          );

          // --------------------------------------------------------------
          // 7. Bob (now admin) clears the ghost via removeMembers.
          //    ASSERTION TWO: the result carries a structurally valid
          //    kind-445 evolution event, ready for relay publication.
          // --------------------------------------------------------------
          final removeResult = await bobCircle.removeMembers(
            mlsGroupId: mlsGroupId,
            memberPubkeys: [alicePub.pubkeyHex],
          );
          expect(
            removeResult.evolutionEventJson,
            isNotEmpty,
            reason: 'removeMembers must emit a non-empty '
                'evolution event JSON.',
          );
          expect(
            removeResult.evolutionEventJson,
            contains('"kind":445'),
            reason: 'The recovery commit must be a kind-445 '
                'Marmot group message.',
          );
          // The outer event uses an ephemeral pubkey per MIP rule 2
          // — must NOT equal Bob's identity pubkey.
          final outerPubkeyMatch = RegExp(
            r'"pubkey"\s*:\s*"([0-9a-fA-F]{64})"',
          ).firstMatch(removeResult.evolutionEventJson);
          expect(outerPubkeyMatch, isNotNull);
          expect(
            outerPubkeyMatch!.group(1)!.toLowerCase(),
            isNot(equals(bobPub.pubkeyHex.toLowerCase())),
            reason: 'Marmot rule 2: outer kind-445 pubkey must be '
                'ephemeral, not the sender identity pubkey.',
          );

          // --------------------------------------------------------------
          // 8. Finalize Bob's local commit so his roster reflects the
          //    eviction. The production code calls finalizePendingCommit
          //    after a successful publish; we mirror that here so the
          //    final member-list assertion is meaningful.
          // --------------------------------------------------------------
          await bobCircle.finalizePendingCommit(mlsGroupId: mlsGroupId);
          final bobMembers = await bobCircle.getMembers(
            mlsGroupId: mlsGroupId,
          );
          expect(
            bobMembers
                .map((m) => m.pubkey.toLowerCase())
                .where((p) => p == alicePub.pubkeyHex.toLowerCase()),
            isEmpty,
            reason: 'After Bob commits the RemoveMember, Alice must no '
                'longer appear in his member list.',
          );

          debugPrint(
            '[ghost_admin_test] OK — ignoredReason='
            '${bobProcessResult.ignoredReason}; '
            'RemoveMember commit length='
            '${removeResult.evolutionEventJson.length}',
          );
        } finally {
          // Best-effort cleanup.
          try {
            await aliceDir.delete(recursive: true);
          } on Object catch (_) {}
          try {
            await bobDir.delete(recursive: true);
          } on Object catch (_) {}
        }
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
