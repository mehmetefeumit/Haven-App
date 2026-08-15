/// FFI-level tripwire for MDK's MIP-03 admin-leave gate.
///
/// MDK refuses to emit a raw `SelfRemove` proposal from a caller that is
/// still an admin: the Dark Matter engine rejects it with the typed
/// `EngineError::AdminCannotSelfRemove` variant, which haven-core's
/// `SessionManager::leave_group` maps (on the VARIANT, never upstream
/// message text) to Haven's stable `NostrError::AdminSelfDemoteRequired` —
/// whose message names the actionable `self-demote` remediation and never
/// embeds the group id. Haven's `LeavePlan`
/// (`haven-core/src/circle/leave.rs`) honours that contract by issuing
/// `propose_admin_handoff` and/or `propose_self_demote` before
/// `propose_leave`, so admins can never reach `propose_leave` while admin
/// themselves through production code. This test exists as a tripwire: if
/// a future MDK rev quietly relaxes the gate, the call here will succeed
/// and the test will fail, surfacing the upstream change before it can
/// produce stale rosters in the field.
///
/// The scenario sets up two parties through `CircleManagerFfi` directly
/// (no UI, no relay), promotes Bob to admin so the admin set has TWO
/// members, and then has Alice — *still admin* — call `proposeLeave`. The
/// assertion is that the call throws an error whose message contains
/// `self-demote` / `self_demote` — satisfied by Haven's stable mapping
/// regardless of upstream wording changes.
///
/// ## Why the 2-admin variant specifically
///
/// A sole-admin rejection is ambiguous: the engine could be refusing
/// because the group would be left admin-less (an `AdminDepletion`-shaped
/// concern) rather than because *any* admin must self-demote before
/// removing itself. Promoting Bob first removes that confound — the group
/// would still have an admin after Alice leaves, so a rejection here can
/// only be the self-demote gate. It rules out a hypothetical "a second
/// admin lets you bypass self-demote" loophole, which is the exact shape
/// the original ghost-admin bug took.
///
/// ## FN-4: Admin precondition assertions
///
/// Before Alice calls `proposeLeave`, the test calls `getMembers` and
/// explicitly asserts:
/// 1. Alice's own `CircleMemberFfi.isAdmin == true` — the tripwire only
///    makes sense if Alice is truly admin at test time.
/// 2. The total admin count equals 2 (the promotion landed).
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
import 'package:integration_test/integration_test.dart';

import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

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
    // Full hermetic process bootstrap, shared with the e2e lanes
    // (test_user.dart): Rust bridge init, in-memory keyring (so the test
    // doesn't need a platform Keystore/Keychain), the debug-only
    // loopback-`ws://` opt-in (so `_testRelayUrl` passes every Rust
    // `validate_relay_urls` call site), and the default-relay override.
    // The override is load-bearing for Dark Matter's KeyPackage discovery:
    // `fetchKeypackage`'s cascade ends at the read-only discovery plane,
    // which mirrors the default-relay override in debug builds — without
    // it, the fetch below would consult the PUBLIC indexers (non-hermetic,
    // and Bob's KeyPackage only exists on the local strfry → null).
    await TestUser.bootstrapProcess(relays: [_testRelayUrl]);
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
        installThrowTimeErrorLogging();
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
          // Bob's pubkey is the successor Alice promotes to admin (step 4).
          final bobPubkeyHex = bobPub.pubkeyHex;
          final bobSecret = await bobIdent.getSecretBytes();

          // --------------------------------------------------------------
          // Two CircleManagerFfi instances — one per party. Dark Matter
          // (DM-4): construction hard-requires the identity secret bytes.
          // --------------------------------------------------------------
          final aliceCircle = await CircleManagerFfi.newInstance(
            dataDir: aliceDir.path,
            identitySecretBytes: aliceSecret,
          );
          final bobCircle = await CircleManagerFfi.newInstance(
            dataDir: bobDir.path,
            identitySecretBytes: bobSecret,
          );

          // --------------------------------------------------------------
          // 1. Bob publishes a KeyPackage so Alice can include him, via the
          //    Dark Matter maintain-key-package path (the ONE publish path).
          //    It probes/publishes to Bob's OWN NIP-65 relays, so seed that
          //    list with the test relay first.
          // --------------------------------------------------------------
          await bobCircle.addUserRelay(
            url: _testRelayUrl,
            relayType: RelayTypeFfi.nip65,
          );
          final bobRelayManager = await RelayManagerFfi.newInstance();
          await bobRelayManager.maintainKeyPackage(
            circle: bobCircle,
            identitySecretBytes: bobSecret,
          );
          final bobKpJson = await bobRelayManager.fetchKeypackage(
            pubkey: bobPub.pubkeyHex,
          );
          expect(
            bobKpJson,
            isNotNull,
            reason: 'Bob must have a discoverable KeyPackage',
          );

          // --------------------------------------------------------------
          // 2. Alice creates the circle with Bob as the only member.
          //    Alice is the sole admin.
          // --------------------------------------------------------------
          final creation = await aliceCircle.createCircle(
            identitySecretBytes: aliceSecret,
            members: [
              MemberKeyPackageFfi(
                keyPackageJson: bobKpJson!,
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

          // Alice confirms her own pending group-creation state (from
          // adding Bob) before subsequent operations on the group
          // (publish-before-apply, Rule 13).
          await aliceCircle.confirmPublished(pending: creation.pending);

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
          // `invitation.mlsGroupId` is the pre-join stand-in id — actually
          // the gift-wrap event id the invitation was keyed by.
          await bobCircle.acceptInvitation(giftWrapId: invitation!.mlsGroupId);

          // --------------------------------------------------------------
          // 4. Alice promotes Bob to admin via an
          //    `UpdateAppComponents(admin-policy.v1)` commit, so the admin
          //    set has TWO members when she attempts her still-admin
          //    proposeLeave below (see the library doc comment for why the
          //    2-admin shape is the load-bearing one). Nothing publishes in
          //    this FFI-level test, so the pending commit is confirmed
          //    directly — the same seam the circle creation above uses.
          // --------------------------------------------------------------
          final promote = await aliceCircle.proposeAdminHandoff(
            mlsGroupId: mlsGroupId,
            successorHex: bobPubkeyHex,
          );
          await aliceCircle.confirmPublished(pending: promote.pending);

          // ==============================================================
          // FN-4: Admin precondition assertions.
          //
          // Before Alice calls proposeLeave, verify via getMembers that:
          // 1. Alice herself is admin (isAdmin == true).
          // 2. The admin count is 2 (the promotion above landed), so the
          //    rejection below cannot be explained by the group being left
          //    admin-less.
          //
          // If either assertion fails, the test surfaces the setup
          // regression separately from the MDK gate being tested.
          // ==============================================================
          final members = await aliceCircle.getMembers(mlsGroupId: mlsGroupId);

          // --- FN-4 precondition 1: Alice is admin ---
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
                'called. As the circle creator she is admin from the start; '
                'if she is not admin here the tripwire test is vacuous — '
                'MDK would reject the call for a different reason.',
          );

          // --- FN-4 precondition 2: exactly 2 admins (Alice + Bob) ---
          final adminCount = members.where((m) => m.isAdmin).length;
          expect(
            adminCount,
            equals(2),
            reason:
                'FN-4: the circle must have TWO admins (Alice + the promoted '
                'Bob) before the gate assertion. Got $adminCount. A count of '
                '1 means proposeAdminHandoff silently failed to grant admin, '
                'which would make the rejection below ambiguous — it could '
                'then be explained by the group being left admin-less rather '
                'than by the self-demote gate this test exists to pin.',
          );

          debugPrint(
            '[admin_leave_gate_test] FN-4 preconditions OK — '
            'Alice isAdmin=true, adminCount=$adminCount',
          );

          // --------------------------------------------------------------
          // 5. Alice — still admin in the group state — attempts a raw
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
