/// FFI-level tripwire for MDK's MIP-03 admin-leave gate.
///
/// MDK refuses to emit a raw `SelfRemove` proposal from a caller that is
/// still an admin: `mdk-core/src/groups.rs::leave_group` errors with
/// `"Admins must self-demote before leaving. Use self_demote() first."`.
/// Haven's `LeavePlan` (`haven-core/src/circle/leave.rs`) honours that
/// contract by issuing `propose_admin_handoff` and/or
/// `propose_self_demote` before `propose_leave`, so admins can never
/// reach `propose_leave` while admin themselves through production code.
/// This test exists as a tripwire: if a future MDK rev quietly relaxes
/// the gate, the call here will succeed and the test will fail, surfacing
/// the upstream change before it can produce stale rosters in the field.
///
/// The scenario sets up two parties through `CircleManagerFfi` directly
/// (no UI, no relay), promotes Bob to admin via `proposeAdminHandoff` so
/// the admin set has two members, and then has Alice — *still admin* —
/// call `proposeLeave`. The assertion is that the call throws an error
/// whose message contains `self-demote` / `self_demote`.
///
/// ## FN-4: Admin precondition assertions
///
/// Before Alice calls `proposeLeave`, the test now calls `getMembers` and
/// explicitly asserts:
/// 1. Alice's own `CircleMemberFfi.isAdmin == true` — the tripwire only
///    makes sense if Alice is truly admin at test time.
/// 2. The total admin count equals 2 after the handoff add (Alice + Bob).
/// This ensures the test diagnoses "wrong admin count going in" separately
/// from "MDK regressed its gate", so a future failure is actionable.
///
/// Acceptance hooks:
///   - A future MDK rev that silently accepts admin SelfRemove makes
///     `proposeLeave` return a result instead of throwing → fails the
///     `caughtError, isNotNull` assertion.
///   - An FFI shim regression that swallows MDK's error string and
///     returns a degenerate result also fails the same assertion.
///   - An FFI shim that surfaces the error but mangles the message
///     (dropping the actionable `self-demote` hint) fails the
///     `errorMessage, contains(...)` assertion.
///   - Alice is not admin (setup regression) → fails the FN-4 isAdmin
///     precondition assertion before we even reach proposeLeave.
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
    // Allow `_testRelayUrl` ("ws://localhost:7777" by default) through
    // any Rust call site that runs `validate_relay_urls`. The test
    // currently uses `CircleManagerFfi` directly and does not touch the
    // relay layer, but opting in defends against a future code path
    // routing those URLs through the validator. Debug-only; release
    // builds physically cannot reach this. See
    // `haven-core/src/relay/manager.rs::allow_ws_loopback_for_test`.
    allowWsLoopbackForTest();
  });

  group('Admin-leave gate (FFI)', () {
    // testWidgets (not bare test): only a testWidgets body's failure reaches
    // the integration binding's results map and can fail the `flutter drive`
    // build. A bare test() failure is swallowed by integrationDriver — which
    // would silently hide a regression of this exact ghost-admin gate. See
    // test/lints/integration_test_propagation_test.dart. The `tester` is unused
    // (this drives the FFI directly, no widget tree).
    testWidgets(
      'MDK rejects proposeLeave from a still-admin caller with a structured '
      'self-demote error (regression target for the upstream ghost-admin fix)',
      (tester) async {
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
          // Alice's pubkey is captured for the FN-4 getMembers lookup.
          final alicePublic = await aliceIdent.loadFromBytes(
            secretBytes: _aliceSeed,
          );
          final alicePubkeyHex = alicePublic.pubkeyHex;
          final aliceSecret = await aliceIdent.getSecretBytes();

          final bobIdent = await NostrIdentityManager.newInstance();
          final bobPub = await bobIdent.loadFromBytes(secretBytes: _bobSeed);
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
          final mlsGroupId = Uint8List.fromList(creation.circle.mlsGroupId);

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
          await bobCircle.acceptInvitation(mlsGroupId: invitation!.mlsGroupId);

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
            reason:
                'Bob must process the handoff commit emitted by '
                'the existing admin (Alice).',
          );
          expect(
            bobAppliedHandoff!.groupUpdated,
            isTrue,
            reason:
                'AdminHandoff is a group-state change; '
                'the joiner side must observe groupUpdated == true.',
          );

          // ==============================================================
          // FN-4: Admin precondition assertions.
          //
          // Before Alice calls proposeLeave, verify via getMembers that:
          // 1. Alice herself is still admin (isAdmin == true).
          // 2. The admin count is 2 (Alice + Bob after handoff).
          //
          // If either assertion fails, the test surfaces the setup
          // regression separately from the MDK gate being tested.
          // ==============================================================
          final members = await aliceCircle.getMembers(mlsGroupId: mlsGroupId);

          // --- FN-4 precondition 1: Alice is still admin ---
          final aliceMember = members.where(
            (m) => m.pubkey.toLowerCase() == alicePubkeyHex.toLowerCase(),
          );
          expect(
            aliceMember,
            isNotEmpty,
            reason:
                'FN-4: Alice must appear in the member list before '
                'proposeLeave. If she is missing, the group state is '
                'corrupted.',
          );
          expect(
            aliceMember.first.isAdmin,
            isTrue,
            reason:
                'FN-4: Alice must still be admin before proposeLeave is '
                'called. The handoff added Bob as admin but did NOT demote '
                'Alice. If Alice is not admin here the tripwire test is '
                'vacuous — MDK would reject the call for a different reason.',
          );

          // --- FN-4 precondition 2: exactly 2 admins (Alice + Bob) ---
          final adminCount = members.where((m) => m.isAdmin).length;
          expect(
            adminCount,
            equals(2),
            reason:
                'FN-4: After proposeAdminHandoff the group must have exactly '
                '2 admins (Alice + Bob). Got $adminCount. '
                'A mismatch means the handoff commit did not propagate '
                'correctly or Alice was already demoted — either is a setup '
                'regression that would make the gate assertion unreliable.',
          );

          debugPrint(
            '[admin_leave_gate_test] FN-4 preconditions OK — '
            'Alice isAdmin=true, adminCount=$adminCount',
          );

          // --------------------------------------------------------------
          // 5. Alice — still admin in the group state (AdminHandoff
          //    promoted Bob but did not demote Alice) — attempts a raw
          //    proposeLeave. MDK's admin-gate must reject the call at
          //    the sender. The pre-fix behaviour was a silent
          //    IgnoredProposal at the receiver; that path is gone in the
          //    pinned MDK rev, so the only observable signal is the
          //    structured Err surfaced over FRB.
          // --------------------------------------------------------------
          Object? caughtError;
          try {
            await aliceCircle.proposeLeave(mlsGroupId: mlsGroupId);
          } on Object catch (e) {
            // Broad catch is intentional and test-scoped: the FFI shim
            // surfaces MDK errors as platform exceptions, and the exact
            // runtime type depends on FRB internals we treat as opaque.
            caughtError = e;
          }

          expect(
            caughtError,
            isNotNull,
            reason:
                'Admin proposeLeave must fail in the pinned MDK '
                'rev. If this passes, MDK has regressed to the '
                'silent-accept behaviour that produced the ghost-admin '
                'bug — every other member would then carry a stale '
                '"Alice is still here" roster forever.',
          );

          final errorMessage = caughtError!.toString().toLowerCase();
          expect(
            errorMessage,
            anyOf(contains('self-demote'), contains('self_demote')),
            reason:
                'MDK admin-gate must surface an actionable error '
                'naming the self-demote remediation. A bare "MLS error" '
                'with no remediation hint would suggest the FFI shim is '
                'swallowing the message — UI code would then have no '
                'reliable way to route an admin to the correct flow. '
                '(error type: ${caughtError.runtimeType}, '
                'message length: ${errorMessage.length} chars)',
          );

          // Log only the error type — the message content is already
          // asserted above, and a raw MDK error string can embed an MLS
          // group id that must not reach CI logs.
          debugPrint(
            '[admin_leave_gate_test] OK — proposeLeave rejected with: '
            '${caughtError.runtimeType}',
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
