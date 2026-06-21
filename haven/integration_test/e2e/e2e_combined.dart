/// Consolidated end-to-end test — Alice through real UI, Bob and Carol
/// as in-process synthetic peers.
///
/// This file replaces the prior multi-role architecture (one Flutter
/// process per role across three coordinated AVDs) with the
/// industry-standard single-process pattern: one runner, one AVD, one
/// Flutter UI process driving Alice through the production UI; Bob and
/// Carol participate in the MLS/Nostr flow as in-process
/// [SyntheticUser] instances coordinated via the same hermetic strfry.
///
/// ## Why this architecture
///
/// The prior multi-AVD design needed ~32 GB of RAM to run cleanly.
/// `ubuntu-latest` ships with ~7 GB usable; three concurrent emulators
/// at 1.5 GB each plus Gradle peak over-commit the host, and the
/// resulting `kswapd0`/`lmkd` thrash ballooned EGL frame times to
/// 1.8–2.7 s — well past anything `tester.pump(100 ms)` can absorb.
///
/// `element-web` (the closest precedent for multi-user E2E messaging
/// tests on GitHub Actions) uses the same single-process pattern: one
/// runner drives one client through the production UI; other users
/// are simulated in-process via bot accounts. Translated to Haven:
/// Alice drives the production Flutter UI, Bob and Carol are
/// `SyntheticUser` instances built on the same FFI surface the
/// production app uses, and all three coordinate through the local
/// strfry container — the same coordination model production Haven
/// uses (Bob's instance only learns of Alice's invitation when a
/// gift-wrap shows up on his inbox relay).
///
/// ## What is covered end-to-end
///
/// - Alice's full UI flow: pre-seeded identity → MapShell mount →
///   CreateCirclePage + NameCirclePage → Circle details + Leave
///   Circle dialog. Every UI gesture is a real `tester.tap`.
/// - The full MLS/Nostr pipeline for all three actors:
///   `signKeyPackageEvent` + relay publish; `create_circle` +
///   gift-wrap delivery; `process_gift_wrapped_invitation` +
///   `accept_invitation`; `encrypt_location` + relay publish +
///   `decrypt_location`; `plan_leave` + `propose_admin_handoff` +
///   `propose_self_demote` + `propose_leave` + `complete_leave`.
/// - Production providers and services on Alice's side:
///   `locationPublisherProvider`, `memberLocationsProvider`,
///   `evolutionPollerProvider`, `circlesProvider` (asserted after
///   Phase 4 with 3 accepted members, and after Phase 5 as empty),
///   the new `_persistDecryptedLocation` shared helper between
///   fetcher and poller paths.
///
/// ## What is NOT covered (and where it lives instead)
///
/// - Bob's and Carol's `InvitationsPage` rebuild on a new gift-wrap,
///   the "Accept" button rendering, the Circle details modal, and the
///   Leave Circle confirmation dialog from a non-Alice perspective.
///   These are widget-level concerns, exercised by `test/widgets/`
///   widget tests that mock the relay and inject deterministic state.
///   The MLS-protocol semantics are identical for Bob, Carol, and
///   Alice — they share the same FFI surface — so covering only
///   Alice's UI is sufficient for the integration-test layer.
/// - The multi-committer admin-handoff fork reconciliation verified
///   through a *remaining* member's production
///   `evolutionPollerProvider`. The `_reconcileHandoff` function
///   proves reconciliation via the synthetic FFI path
///   (`applyArrivalOrdered`). Alice is the founding admin who leaves;
///   she is never a remaining member observing a handoff. Closing
///   this gap requires either a 4-member circle (Alice, Bob, Carol,
///   Dave — Alice leaves as admin so Bob/Carol remain; Carol's
///   production poller picks up the fork) or an admin-grant flow
///   (Alice promotes Bob, Bob leaves, Alice remains and her production
///   poller observes the handoff). Both are genuine restructures that
///   risk the working scenario; this is estimated as a separate,
///   larger change. See also docs/E2E_TROUBLESHOOTING.md
///   §"Known coverage gaps".
///
/// ## Scenario phases
///
/// 1. **setUpAll**: Rust bridge + in-memory keyring + relay override,
///    pre-seed Alice's identity into `flutter_secure_storage`,
///    bootstrap Bob and Carol as [SyntheticUser] instances (publishes
///    their KeyPackages to the hermetic strfry).
/// 2. **Pump HavenApp**: lands on `MapShell` with Alice's identity
///    loaded and the geolocator replaced by the deterministic fake.
/// 2a. **Alice creates a 2-member circle (Alice + Bob)** via the
///    production UI. One kind-1059 gift-wrap lands on strfry; the test
///    gates on it via `TestRelay.firstWhere`. Alice's and Bob's epochs
///    are recorded after the circle is created.
/// 3a. **Bob accepts via FFI**: `SyntheticUser.acceptInvitationViaRelay`
///    reproduces the `InvitationPoller → process_gift_wrapped_invitation
///    → accept_invitation` chain without the UI. Asserts MDK member set
///    has exactly [Alice, Bob].
/// 2b. **NEW — Alice adds Carol via the AddMemberPage UI**: opens the
///    circle-details sheet, taps "Add member" (`addMemberCta`), enters
///    Carol's npub, confirms (`addMemberConfirm`). Asserts on the relay:
///    exactly 1 new kind-1059 gift-wrap to Carol; exactly 1 new kind-445
///    Add commit with a DISTINCT ephemeral pubkey and `#h`=nostr_group_id.
///    Asserts epoch: Alice advanced by exactly 1; after Bob drains the
///    Add commit, Bob's epoch also advanced by exactly 1.
/// 3b. **Carol accepts via FFI**: joins at the post-add epoch. Asserts
///    all three peers see [Alice, Bob, Carol]; Carol's epoch equals
///    Alice's epoch (joined at the Add epoch). Carol republishes a fresh
///    KeyPackage. Behavioral forward-secrecy check: Carol CAN decrypt a
///    location Alice publishes AFTER the add; Carol CANNOT decrypt the
///    pre-add location captured before the add.
/// 4. **Three-way location sharing**: Alice's `locationPublisherProvider`
///    fires, Bob and Carol publish via FFI, all three drain the
///    relay. Alice's `memberLocationsProvider` is the source of truth
///    for the UI side; Bob's and Carol's FFI `getMembers` view is the
///    source of truth for the synthetic-peer side.
/// 5. **Alice (admin) leaves via UI**: `LeavePlan::AdminHandoff` runs
///    underneath, emitting the three-commit sequence
///    `AdminHandoff → SelfDemote → SelfRemove`. Bob and Carol drain
///    the commits via FFI. Exactly one of them ends up `isAdmin=true`
///    (lex-smallest non-self per `select_successor`). Epoch deltas
///    asserted on the winner (committer's epoch advanced) and the
///    loser (adopts winner's commit, epoch also advances).
/// 6. **Non-admin leaves via FFI**: the residual member who is NOT
///    admin calls `SyntheticUser.leaveAsNonAdmin`; the remaining
///    admin drains the SelfRemove and asserts the leaver is gone.
///    Admin's epoch advances by exactly 1.
/// 7. **Forward secrecy after removal**: the evicted leaver MUST NOT
///    decrypt a location published by the admin after removal.
///
/// ## Acceptance hooks
///
/// Reverting any of the following to a no-op turns this scenario red:
/// - `NostrCircleService.createCircle` — gift-wrap waits time out.
/// - `NostrCircleService.addMember` — Carol's gift-wrap wait times out,
///   epoch-delta assertions fail, Bob's epoch never advances on the
///   Add-commit drain.
/// - `signKeyPackageEvent` — Alice's circle-creation flow fails KP
///   validation for Bob.
/// - `CircleManagerFfi.acceptInvitation` — Bob's MDK member-set
///   assertion fails (still 1 member after accept); Carol similarly.
/// - `CircleManagerFfi.groupEpochForTest` — epoch-delta assertions throw.
/// - `encryptLocation` — Alice's relay-side wait for kind-445 fires.
/// - `decryptLocation` — neither side surfaces the other's location;
///   Carol's forward-secrecy cross-check fails.
/// - The shared `_persistDecryptedLocation` helper in
///   `location_sharing_service.dart` — Alice's `memberLocationsProvider`
///   stays empty.
/// - `LeavePlan::AdminHandoff`'s `propose_admin_handoff` or
///   `propose_self_demote` — Alice's leave fails at MDK's admin gate;
///   Bob/Carol's residual-state assertion (`adminCount == 1`) fails.
/// - `LeavePlan::NonAdmin` — non-admin's `leaveAsNonAdmin` throws or
///   the admin's drain never sees the SelfRemove.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint, listEquals;
import 'package:flutter/material.dart' show FilledButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/add_member_page.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleWithMembersFfi,
        InvitationFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/circle_service.dart' show Circle, MembershipStatus;
import 'package:haven/src/services/location_sharing_service.dart' show MemberLocation;
import 'package:haven/src/services/nostr_circle_service.dart' show NostrCircleService;
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/diagnostics.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/sheet_helpers.dart';
import '_lib/synthetic_user.dart' show DecryptedCoords, SyntheticUser;
import '_lib/test_relay.dart' show TestRelay, TestRelayEvent;
import '_lib/test_user.dart';

// =============================================================================
// Constants
// =============================================================================

/// Circle name Alice types into the form.
const String _circleName = 'Family';

/// Outer deadline on relay-level waits for a kind-1059 gift-wrap to
/// land. 90 s covers a cold-AVD `create_circle` FFI + a slow strfry
/// session-start; warm runs land in well under 10 s.
///
/// Bob's and Carol's KeyPackages are published synchronously in
/// `setUpAll`, so the `waitForKeyPackage` lookups rely on the
/// `coordination.dart` default (30 s) — same envelope, no override.
const Duration _giftWrapDeadline = Duration(seconds: 90);

/// Overall test budget. Worst case ~5 min on a cold AVD; 12 min
/// leaves comfortable headroom while still exposing real hangs as
/// clean assertion failures rather than the outer harness timeout.
const Duration _outerTestTimeout = Duration(minutes: 12);

/// How long the test waits for Bob/Carol's MDK to converge after
/// each commit batch. Used both during the 3-way location step and
/// during admin handoff observation.
const Duration _peerConvergenceBudget = Duration(seconds: 60);

/// Sleep between convergence-poll attempts. Empirical: relay + MLS
/// convergence is genuinely async with no single gating wire event,
/// so we poll. Centralized here so the cadence can be tuned in one
/// place if a CI emulator is consistently slower than one round-trip.
const Duration _convergencePollInterval = Duration(seconds: 3);

/// Tolerance when comparing a decrypted coordinate to its sentinel.
///
/// The sentinel coords are plain f64 constants round-tripped through
/// kind-9 JSON → Rust → Dart; the loss is sub-ULP. 1e-5 (~1 m of
/// latitude) is far wider than any round-trip noise yet orders of
/// magnitude tighter than any real corruption, so it detects a
/// decrypt-but-corrupt bug without risking float-precision flake.
const double _coordEpsilon = 1e-5;

// =============================================================================
// Entry point
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `late` keeps the test body ergonomic; the `_didInit*` sentinels
  // make `tearDownAll` safe against a partial `setUpAll` failure —
  // without them a `LateInitializationError` in `tearDownAll`
  // cascades onto the original failure and masks the real cause in
  // CI artifacts.
  late ScenarioContext ctx;
  late SyntheticUser bob;
  late SyntheticUser carol;
  var didInitCtx = false;
  var didInitPreSeed = false;
  var didInitBob = false;
  var didInitCarol = false;

  setUpAll(() async {
    // Fresh SharedPreferences state — the pre-seed helper writes the
    // onboarding flags atop a known-empty baseline.
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // ScenarioHarness initialises the Rust bridge, installs the in-
    // memory keyring, applies the loopback-only relay override, and
    // opens a TestRelay probe socket to strfry.
    ctx = await ScenarioHarness.bootstrap();
    didInitCtx = true;

    // Pre-seed Alice's identity from her sentinel seed and skip
    // onboarding. The production identity-loading + KeyPackagePublisher
    // providers run exactly as in a real install — only the seed
    // source differs (sentinel vs. RNG). The interactive UI onboarding
    // flow is a separate concern, covered by widget tests under
    // `test/pages/onboarding/`.
    await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
    didInitPreSeed = true;

    // Cache Alice's pubkey hex up-front so the sync helper
    // `_alicePubkeyHex` in this file can return it without awaiting
    // the FFI from inside the test body.
    await _prepareAlicePubkey();

    // Bob and Carol as in-process synthetic peers. Each construction
    // publishes a KeyPackage (kind 30443 + legacy 443) to strfry so
    // Alice's `CreateCirclePage` can resolve them when she types
    // their npubs.
    bob = await SyntheticUser.bob(ctx.relay);
    didInitBob = true;
    carol = await SyntheticUser.carol(ctx.relay);
    didInitCarol = true;

    debugPrint(
      '[e2e_combined:setUpAll] '
      'alice.pubkey=${_redactPk(_alicePubkeyHex())} '
      'bob.pubkey=${_redactPk(bob.pubkeyHex)} '
      'carol.pubkey=${_redactPk(carol.pubkeyHex)}',
    );
  });

  tearDownAll(() async {
    if (didInitCarol) {
      await carol.dispose();
    }
    if (didInitBob) {
      await bob.dispose();
    }
    if (didInitPreSeed) {
      await TestUser.clearPreSeededIdentity();
    }
    if (didInitCtx) {
      await ctx.relay.dispose();
    }
  });

  testWidgets(
    'Alice UI + Bob/Carol FFI: 3-member invite → 3-way locations → '
    'admin leave (handoff) → non-admin leave',
    (tester) async {
      // PRIVACY WATCH — start BEFORE anything is pumped or published so
      // we observe every event for the whole run. Haven's privacy model
      // forbids publishing kind-0 profiles (no relay-level username↔
      // pubkey correlation). Buffer any kind-0 the relay sees from any
      // author; assert empty at the end. Relay-layer, so robust to any
      // UI change.
      final profileEvents = <TestRelayEvent>[];
      final profileWatch = ctx.relay
          .events(<String, dynamic>{'kinds': const <int>[0]})
          .listen(profileEvents.add);
      try {
        // -----------------------------------------------------------
        // PHASE 1 — pump HavenApp with the pre-seeded identity and
        // the production geolocator replaced by a deterministic fake.
        // -----------------------------------------------------------
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
          displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
          completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Mirrors production main()'s bootstrap: feed the pre-
              // seeded flags so AppRouter routes straight to MapShell
              // instead of starting an onboarding flow.
              onboardingControllerProvider.overrideWith(
                (ref) => OnboardingController(flags),
              ),
              // Without the fake, `locationPublisherProvider` calls
              // the real Geolocator which has no permission in CI
              // and no GPS fix on a headless emulator. The fake
              // satisfies the production interface end-to-end so the
              // publish path runs linearly with no permission-denied
              // early exits.
              locationServiceProvider.overrideWithValue(
                FakeLocationService(
                  latitude: aliceFakeLatitude,
                  longitude: aliceFakeLongitude,
                ),
              ),
            ],
            child: const HavenApp(),
          ),
        );
        // pumpUntilFound, not pumpAndSettle — MapShell's initState
        // installs three periodic timers (evolution 60 s, location-
        // receive 30 s, foreground heartbeat) that fire before
        // pumpAndSettle ever sees an empty frame queue, leaving the
        // test silently blocked on this await for the full outer
        // timeout. See `_lib/pump_helpers.dart` for the canonical
        // rationale.
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          description: 'MapShell after pumpWidget',
        );

        // -----------------------------------------------------------
        // PHASE 2a — Alice creates a 2-member circle (Alice + Bob)
        // via UI.
        //
        // Carol's KeyPackage is already published to the relay in
        // setUpAll (her bootstrap call above), but she is NOT invited
        // at creation time. The Add-member flow (Phase 2b) invites her
        // post-creation, which is the core scenario this test adds.
        // -----------------------------------------------------------
        final initCommitPubkey = await _aliceCreatesTwoMemberCircle(
          tester: tester,
          ctx: ctx,
          bob: bob,
        );

        // -----------------------------------------------------------
        // PHASE 3a — Bob accepts his invitation via FFI.
        //
        // The production InvitationPoller + accept_invitation chain
        // runs identically; only the UI rebuild is skipped. After
        // accept, Bob's local MDK state has exactly [Alice, Bob].
        // -----------------------------------------------------------
        final bobCircle = await bob.acceptInvitationViaRelay(
          relay: ctx.relay,
        );
        _assertCircleHasMembers(
          label: 'bob (after 2-member create)',
          circle: bobCircle,
          expectedPubkeyHexes: <String>[
            _alicePubkeyHex(),
            bob.pubkeyHex,
          ],
        );

        // -----------------------------------------------------------
        // PRE-ADD LOCATION — 2-member phase (Alice + Bob only).
        //
        // Bob publishes a location while the group is at the init
        // epoch (before Alice adds Carol). This event is encrypted
        // under the init-epoch exporter secret that Carol will never
        // hold: she joins at epochBeforeAdd+1 via the Add Welcome, so
        // MDK never delivers the epoch-N symmetric key to her.
        //
        // We capture the raw relay event NOW, confirm Bob CAN decrypt
        // it (proving the event is valid and on the relay), then pass
        // it into _carolAcceptsAndEpochCheck so Carol's negative
        // assertion runs after she has accepted — Phase 3b (below).
        //
        // Placement rationale: this MUST be BEFORE the AddMemberPage
        // UI gestures in _aliceAddsCarolViaUi so it does not
        // interleave with the Add flow. The subscription and publish
        // are fully resolved (relay OK + relay observable) before
        // _aliceAddsCarolViaUi touches the UI.
        // -----------------------------------------------------------
        final mlsGroupId = bobCircle.circle.mlsGroupId;
        final nostrGroupIdHexForPreAdd = _hexLower(
          bobCircle.circle.nostrGroupId,
        );

        // Subscribe for the pre-add location event BEFORE Bob publishes
        // so we never race the relay's delivery latency.
        final preAddEventFuture = ctx.relay.firstWhere(
          filter: <String, dynamic>{
            'kinds': const <int>[445],
            '#h': <String>[nostrGroupIdHexForPreAdd],
            'since': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'limit': 5,
          },
        );

        // Bob publishes a location at the init epoch (2-member group;
        // Carol has NOT joined yet). publishLocation encrypts via Bob's
        // local MDK which holds epoch secrets Carol will never possess.
        final preAddEventId = await bob.publishLocation(
          circle: bobCircle,
          latitude: bobFakeLatitude,
          longitude: bobFakeLongitude,
          relay: ctx.relay,
        );

        // Wait for the event to be observable on the relay (non-vacuous:
        // proves it is genuinely stored, not just queued).
        final preAddEvent = await preAddEventFuture;
        expect(
          preAddEvent.id,
          equals(preAddEventId),
          reason:
              'PRE-ADD: the first kind-445 landing after the subscription '
              'should be the event Bob just published '
              '(id=${_redactPk(preAddEventId)}). A mismatch means a stale '
              'or unexpected event arrived instead.',
        );

        // Positive control: Bob IS a member at the init epoch and MUST
        // be able to decrypt his own pre-add location event. Uses
        // applyArrivalOrdered with the single captured event, the same
        // path the production drain uses.
        //
        // Bob just published this event via publishLocation; his MDK's
        // seen-event cache has not processed it yet (encryptLocation does
        // not mark events as seen; only decryptLocation does). The first
        // call to applyArrivalOrdered therefore goes through the full
        // decrypt path and Bob's sender pubkey appears in
        // decryptedLocationSenders.
        final preAddBobSummary = await bob.applyArrivalOrdered(
          <TestRelayEvent>[preAddEvent],
          relay: ctx.relay,
        );
        expect(
          preAddBobSummary.decryptedLocationSenders.contains(
            bob.pubkeyHex.toLowerCase(),
          ),
          isTrue,
          reason:
              'PRE-ADD positive control: Bob must decrypt his own pre-add '
              'location event on the first applyArrivalOrdered call — he '
              'is a member at the init epoch and holds the correct exporter '
              'secret, and his MDK seen-cache has not yet processed this '
              'freshly-published event. '
              'decryptedSenders=${preAddBobSummary.decryptedLocationSenders} '
              'decryptFailed=${preAddBobSummary.decryptFailed}',
        );
        // Guard: decrypting a location message must NOT trigger an MLS
        // auto-commit. If MDK emitted a commit here it would advance Bob's
        // epoch silently and corrupt the "+1" baseline we capture below.
        // `groupUpdatesProcessed` counts committed MLS operations in this
        // drain round; it must be 0 for a pure application message.
        expect(
          preAddBobSummary.groupUpdatesProcessed,
          equals(0),
          reason:
              'PRE-ADD epoch baseline: Bob must not advance his MLS epoch '
              'while decrypting his own pre-add location message. '
              'groupUpdatesProcessed='
              '${preAddBobSummary.groupUpdatesProcessed}. '
              'A non-zero value means MDK auto-committed during the positive '
              'control drain, which would silently offset bobEpochBeforeAdd '
              'and make the subsequent +1 epoch assertion vacuous.',
        );
        debugPrint(
          '[e2e_combined] PRE-ADD location publish + Bob-positive-control OK — '
          'eventId=${_redactPk(preAddEventId)}',
        );

        final epochBeforeAdd = await _aliceEpochForTest(tester, mlsGroupId);
        final bobEpochBeforeAdd = await bob.currentEpoch(mlsGroupId);
        debugPrint(
          '[e2e_combined] PHASE 2b pre-add epochs — '
          'alice=$epochBeforeAdd bob=$bobEpochBeforeAdd',
        );

        final carolCircle = await _aliceAddsCarolViaUi(
          tester: tester,
          ctx: ctx,
          bob: bob,
          carol: carol,
          initCommitPubkey: initCommitPubkey,
          epochBeforeAdd: epochBeforeAdd,
          bobEpochBeforeAdd: bobEpochBeforeAdd,
          bobCircle: bobCircle,
        );

        // -----------------------------------------------------------
        // PHASE 3b — Carol accepts her invitation via FFI.
        //
        // Carol joins at the post-add epoch. After accept:
        //   - All three peers see [Alice, Bob, Carol].
        //   - Carol's epoch equals Alice's current epoch (joined at
        //     the Add epoch — the same epoch the Add commit created).
        //   - A fresh KeyPackage from Carol appears on the relay
        //     (her consumed KP is rotated on accept).
        // A behavioral forward-secrecy cross-check proves Carol can
        // decrypt post-add traffic but not pre-add traffic.
        // -----------------------------------------------------------
        await _carolAcceptsAndEpochCheck(
          tester: tester,
          ctx: ctx,
          carol: carol,
          bob: bob,
          carolCircle: carolCircle,
          mlsGroupId: mlsGroupId,
          epochBeforeAdd: epochBeforeAdd,
          preAddLocationEvent: preAddEvent,
        );

        // -----------------------------------------------------------
        // PHASE 4 — Three-way location sharing.
        //
        // Alice's `locationPublisherProvider` produces an encrypted
        // kind-445 to the relay; Bob and Carol publish via FFI; all
        // three observe each other.
        // -----------------------------------------------------------
        await _publishAndObserveThreeWayLocations(
          tester: tester,
          ctx: ctx,
          bob: bob,
          carol: carol,
          bobCircle: bobCircle,
          carolCircle: carolCircle,
        );

        // Relay-layer privacy invariants on the kind-445 traffic
        // produced so far (ephemeral-key-per-message, no real MLS
        // group id on the wire). Robust to any UI change.
        await _assertWirePrivacyInvariants(
          relay: ctx.relay,
          circle: bobCircle,
          identityPubkeyHexes: <String>{
            _alicePubkeyHex().toLowerCase(),
            bob.pubkeyHex.toLowerCase(),
            carol.pubkeyHex.toLowerCase(),
          },
        );

        // Production-provider assertion: Alice's circlesProvider must
        // reflect the "Family" circle with exactly 3 accepted members,
        // proving that her production circle/evolution state (not merely
        // the memberLocationsProvider) has converged end-to-end.
        await _assertAliceCirclesProviderHasFamily(
          tester: tester,
          expectedMemberPubkeyHexes: <String>[
            _alicePubkeyHex(),
            bob.pubkeyHex,
            carol.pubkeyHex,
          ],
        );

        // -----------------------------------------------------------
        // PHASE 5 — Alice (sole admin) leaves via UI.
        //
        // `LeavePlan::AdminHandoff` runs invisibly: promote the
        // lex-smallest non-self member, self-demote, then publish a
        // SelfRemove PROPOSAL — three events across three MLS epochs
        // that MUST be applied in order.
        //
        // We open a LIVE kind-445 subscription BEFORE Alice leaves so
        // the commits are captured in wire-arrival order, which —
        // because Alice publishes them sequentially (awaiting each
        // relay OK) — is exactly MLS-epoch order. Feeding the peers
        // events in that order avoids the sticky-`Unprocessable`
        // cache poisoning that a post-hoc `created_at` sort cannot
        // prevent (1-second resolution can't order same-second
        // commits). See docs/E2E_TROUBLESHOOTING.md.
        //
        // The SelfRemove PROPOSAL is committed by a remaining member.
        // Per RFC 9420 §12.1.2 (and matching whitenoise), EVERY
        // remaining member auto-commits it, so Bob and Carol each
        // produce a competing epoch-3→4 commit — a transient fork.
        // The protocol resolves this by reconciliation: MDK's
        // `is_better_candidate` deterministically elects one winner
        // (earliest timestamp, then lowest event id) and the loser
        // rolls back and adopts it. `_reconcileHandoff` drives both
        // peers until that reconciliation completes and verifies it
        // behaviorally (see its doc) before Phase 6 proceeds.
        //
        // The inbox is shared by both peers (the commits are the same
        // events on the relay); each peer applies them to its own MDK.
        // -----------------------------------------------------------
        // Record epochs for Bob and Carol BEFORE Alice leaves, so we can
        // assert the committer's epoch advanced by exactly 1 after the
        // handoff reconciliation. carolCircle was returned by
        // _aliceAddsCarolViaUi (which internally called
        // carol.acceptInvitationViaRelay); its mlsGroupId is stable
        // throughout the group lifetime.
        final bobEpochBeforeHandoff =
            await bob.currentEpoch(bobCircle.circle.mlsGroupId);
        final carolEpochBeforeHandoff =
            await carol.currentEpoch(carolCircle.circle.mlsGroupId);
        debugPrint(
          '[e2e_combined] PHASE 5 pre-handoff epochs — '
          'bob=$bobEpochBeforeHandoff carol=$carolEpochBeforeHandoff',
        );

        final handoffInbox = _ArrivalOrderedInbox(
          relay: ctx.relay,
          nostrGroupId: bobCircle.circle.nostrGroupId,
        );
        final CircleWithMembersFfi residualBobCircle;
        final CircleWithMembersFfi residualCarolCircle;
        try {
          await _aliceLeavesViaUi(
            tester: tester,
            nostrGroupIdHex: _hexLower(bobCircle.circle.nostrGroupId),
          );

          // Production-provider assertion: Alice's circlesProvider must
          // now be empty — proving the production AdminHandoff leave
          // path updated her real provider state, not merely that the
          // circle tile text disappeared from the UI.
          //
          // NOTE — residual coverage gap (see docs/E2E_TROUBLESHOOTING.md
          // §"Known coverage gaps"): the multi-committer fork reconciliation
          // driven by `_reconcileHandoff` below is verified only through the
          // synthetic FFI path (`applyArrivalOrdered`), not through a
          // *remaining* member's production `evolutionPollerProvider`. Alice
          // is the founding admin who leaves here; she is never a remaining
          // member observing another admin's handoff. Closing this gap
          // requires a 4-member circle or an admin-grant flow, and is
          // estimated as a separate, larger change.
          await _assertAliceCirclesProviderIsEmpty(tester: tester);

          final residual = await _reconcileHandoff(
            bob: bob,
            carol: carol,
            inbox: handoffInbox,
            relay: ctx.relay,
            bobCircle: bobCircle,
            carolCircle: carolCircle,
          );
          residualBobCircle = residual.bob;
          residualCarolCircle = residual.carol;
        } finally {
          await handoffInbox.dispose();
        }

        // -----------------------------------------------------------
        // Epoch-delta assertions after the AdminHandoff reconciliation.
        //
        // Alice's AdminHandoff emits THREE commits:
        //   epoch N   → AdminHandoff (promote successor)
        //   epoch N+1 → SelfDemote   (Alice demotes herself)
        //   epoch N+2 → SelfRemove   (Alice leaves; winner commits it)
        //
        // The winner (sole committer per `_reconcileHandoff`'s
        // single-committer election) advances by 3 from their
        // pre-handoff epoch to N+3 (they finalize Alice's 3 commits +
        // their own SelfRemove auto-commit). The loser clears their
        // own pending auto-commit and applies the winner's commit
        // instead, also landing at N+3.
        //
        // Both peers started at the same epoch (the post-add epoch ==
        // epochBeforeAdd+1 from Phase 2b), so both must end at
        // bobEpochBeforeHandoff+3 (== carolEpochBeforeHandoff+3 since
        // they were equal before the handoff).
        //
        // (The exact delta of 3 is the AdminHandoff: AdminHandoff +
        // SelfDemote + SelfRemove commit = 3 MLS epochs per
        // `LeavePlan::AdminHandoff`.)
        // -----------------------------------------------------------
        final bobEpochAfterHandoff =
            await bob.currentEpoch(residualBobCircle.circle.mlsGroupId);
        final carolEpochAfterHandoff =
            await carol.currentEpoch(residualCarolCircle.circle.mlsGroupId);
        expect(
          bobEpochAfterHandoff,
          equals(bobEpochBeforeHandoff + 3),
          reason:
              "PHASE 5: Bob's epoch must advance by exactly 3 after the "
              'AdminHandoff (3 commits: AdminHandoff → SelfDemote → '
              'SelfRemove). Before=$bobEpochBeforeHandoff, '
              'after=$bobEpochAfterHandoff.',
        );
        expect(
          carolEpochAfterHandoff,
          equals(carolEpochBeforeHandoff + 3),
          reason:
              "PHASE 5: Carol's epoch must advance by exactly 3 after "
              'the AdminHandoff (single-committer election: loser '
              "adopts winner's commit). "
              'Before=$carolEpochBeforeHandoff, '
              'after=$carolEpochAfterHandoff.',
        );
        debugPrint(
          '[e2e_combined] PHASE 5 epoch deltas OK — '
          'bob: $bobEpochBeforeHandoff → $bobEpochAfterHandoff (+3), '
          'carol: $carolEpochBeforeHandoff → $carolEpochAfterHandoff (+3)',
        );
        _assertResidualGroupAfterHandoff(
          label: 'bob',
          circle: residualBobCircle,
          selfPubkeyHex: bob.pubkeyHex,
          peerPubkeyHex: carol.pubkeyHex,
        );
        _assertResidualGroupAfterHandoff(
          label: 'carol',
          circle: residualCarolCircle,
          selfPubkeyHex: carol.pubkeyHex,
          peerPubkeyHex: bob.pubkeyHex,
        );

        // -----------------------------------------------------------
        // PHASE 6 — Non-admin leaves via FFI; admin observes.
        //
        // Record the admin's epoch before the non-admin leaves so we
        // can assert it advanced by exactly 1 after the SelfRemove
        // commit is applied. We don't know yet which of Bob/Carol is
        // the admin; `_nonAdminLeavesAndAdminObserves` identifies that
        // and returns the admin. We record BOTH epochs and use the
        // admin's one after the call.
        //
        // Returns the admin (sole remaining member), the evicted
        // leaver, and the admin's up-to-date 1-member residual circle
        // so Phase 7 can drive the forward-secrecy contrast without
        // re-deriving which peer is which.
        // -----------------------------------------------------------
        final bobEpochBeforeNonAdminLeave =
            await bob.currentEpoch(residualBobCircle.circle.mlsGroupId);
        final carolEpochBeforeNonAdminLeave =
            await carol.currentEpoch(residualCarolCircle.circle.mlsGroupId);
        final phase6 = await _nonAdminLeavesAndAdminObserves(
          ctx: ctx,
          bob: bob,
          carol: carol,
          bobCircle: residualBobCircle,
          carolCircle: residualCarolCircle,
        );

        // Assert the admin's epoch advanced by exactly 1 after the
        // non-admin's SelfRemove commit was applied. The non-admin's
        // proposeLeave + completeLeave is one MLS commit, so the admin
        // advances by exactly 1 when they apply it.
        final adminEpochAfterLeave =
            await phase6.admin.currentEpoch(
              phase6.adminResidual.circle.mlsGroupId,
            );
        final adminEpochBeforeLeave = phase6.admin.label == 'bob'
            ? bobEpochBeforeNonAdminLeave
            : carolEpochBeforeNonAdminLeave;
        expect(
          adminEpochAfterLeave,
          equals(adminEpochBeforeLeave + 1),
          reason:
              "PHASE 6: the admin's epoch must advance by exactly 1 after "
              "the non-admin's SelfRemove commit is applied. "
              'admin=${phase6.admin.label}, '
              'before=$adminEpochBeforeLeave, '
              'after=$adminEpochAfterLeave.',
        );
        debugPrint(
          '[e2e_combined] PHASE 6 epoch delta OK — '
          '${phase6.admin.label}: $adminEpochBeforeLeave → '
          '$adminEpochAfterLeave (+1, non-admin SelfRemove)',
        );

        // -----------------------------------------------------------
        // PHASE 7 — Forward secrecy after removal.
        //
        // The admin publishes a FRESH post-removal location; the
        // evicted leaver MUST NOT be able to decrypt it — the inverse
        // of Phase 4, where cross-peer decrypt provably worked while
        // the leaver was still a member.
        // -----------------------------------------------------------
        await _assertForwardSecrecyAfterRemoval(
          ctx: ctx,
          admin: phase6.admin,
          leaver: phase6.leaver,
          adminResidual: phase6.adminResidual,
        );

        // Privacy model: NO kind-0 profile may have been published by
        // anyone for the entire run (relays must never see a
        // username↔pubkey mapping). Asserted at the very end so it
        // covers identity load, circle creation, invites, locations,
        // and both leave flows.
        expect(
          profileEvents,
          isEmpty,
          reason:
              'Haven must never publish a kind-0 profile (privacy model) '
              '— the relay observed ${profileEvents.length} during the run.',
        );

        debugPrint('[e2e_combined] all phases complete ✓');
      } on Object {
        // Flush observable state into logcat before re-throwing so
        // the CI failure artifact carries enough context to triage
        // without re-running locally.
        await dumpScenarioState(
          tester: tester,
          ctx: ctx,
          label: 'e2e_combined_failure',
        );
        rethrow;
      } finally {
        await profileWatch.cancel();
      }
    },
    timeout: const Timeout(_outerTestTimeout),
  );

  // ===========================================================================
  // FE-2 — Decline / ignore invitation
  //
  // A synthetic "Dave" receives a gift-wrapped Welcome but NEVER calls
  // `acceptInvitation`. The test asserts two things:
  //   1. Dave's MDK state never advances past the pending-invitation stage:
  //      `getMembers` on Dave's local group throws or the group does not
  //      exist, because the Welcome was never applied.
  //   2. Alice's MLS group member list (from `getMembers` on the creator
  //      side) contains ONLY Alice herself — Dave is absent because Alice
  //      never received an MLS Join commit from him.
  //
  // ## Why this is the right FFI-level assertion
  //
  // In MLS (RFC 9420), a peer does not exist in the group state until an
  // existing member's `Commit(Add)` has been processed. The `createCircle`
  // FFI builds Alice's local group with only Alice as the initial member; it
  // ADDITIONALLY builds gift-wrapped Welcome events for Dave, but those go
  // through the MLS Welcome path: until Dave calls `acceptInvitation` (which
  // runs MDK `accept_welcome` → `into_group` and lets the group apply his
  // join), Alice never commits an Add and neither side's local MDK ever sees
  // Dave as an accepted member. Alice's `getMembers` therefore always returns
  // just herself.
  //
  // On Dave's side, `processGiftWrappedInvitation` decrypts the Welcome and
  // persists a Pending circle row. We assert that state through the production
  // pending API: the invitation appears in `getPendingInvitations()` (which
  // the core filters to Pending-status memberships) and is ABSENT from
  // `getVisibleCircles()` (Accepted-only). `getCircle` is deliberately NOT
  // used — it resolves members via MDK's active group store, which has no
  // group for an unaccepted Welcome (see the inline note at the assertion).
  //
  // ## Determinism
  //
  // Entirely FFI-level: no wall-clock sleeps, no retries. Alice creates the
  // group synchronously via `createCircle`; we publish Dave's gift-wrap to
  // the hermetic relay and wait for it with `TestRelay.firstWhere` (bounded
  // by `_giftWrapDeadline`). Dave processes it synchronously and returns
  // without calling `acceptInvitation`. No `_pollUntil` needed because
  // neither Alice's nor Dave's assertion depends on relay convergence after
  // the initial gift-wrap delivery.
  //
  // ## Acceptance hook
  //
  // Commenting out `acceptInvitation` in production code OR commenting out
  // the `createCircle` gift-wrap publish path makes this test red:
  //   - Without the gift-wrap: `relay.firstWhere(kind 1059)` times out.
  //   - Without accept: assertion (1) already passes; but removing the
  //     gift-wrap publish would falsely make assertion (1) vacuous (Dave
  //     never has a pending invitation to ignore). The relay-level wait
  //     guards against that.
  //   - If someone accidentally wires an auto-accept into the MLS
  //     processing path: Alice's `getMembers` gains Dave, failing
  //     assertion (2).
  // ===========================================================================
  group('FE-2: decline/ignore invitation', () {
    late TestRelay fe2Relay;
    late SyntheticUser fe2Alice;
    late SyntheticUser fe2Dave;
    var fe2DidInitRelay = false;
    var fe2DidInitAlice = false;
    var fe2DidInitDave = false;

    setUpAll(() async {
      // The process-global bridge/keyring/relay override was installed by
      // the outer `setUpAll`. We open a fresh relay probe socket here so
      // this group's WebSocket state is isolated from the main scenario's
      // probe, but we do NOT call `TestUser.bootstrapProcess` again (its
      // OnceLock is already set and the relay URL is unchanged).
      fe2Relay = await TestRelay.connect();
      fe2DidInitRelay = true;

      // Fresh Alice (own temp dir, own SQLCipher state). Uses aliceSeed
      // so her pubkey is known-stable for log correlation. Her KP is
      // published to the relay by `bootstrap` (not needed by this
      // scenario but harmless).
      fe2Alice = await SyntheticUser.bootstrap(
        label: 'fe2_alice',
        seed: aliceSeed,
        relay: fe2Relay,
      );
      fe2DidInitAlice = true;

      // Dave (seed 0x04) — the invitee who will silently ignore the
      // gift-wrap. His KP must be on the relay before Alice calls
      // `fetchMemberKeypackage`.
      fe2Dave = await SyntheticUser.dave(fe2Relay);
      fe2DidInitDave = true;

      debugPrint(
        '[FE-2:setUpAll] alice=${_redactPk(fe2Alice.pubkeyHex)} '
        'dave=${_redactPk(fe2Dave.pubkeyHex)}',
      );
    });

    tearDownAll(() async {
      if (fe2DidInitDave) await fe2Dave.dispose();
      if (fe2DidInitAlice) await fe2Alice.dispose();
      if (fe2DidInitRelay) await fe2Relay.dispose();
    });

    testWidgets(
        'Dave ignores gift-wrap → never accepts (stays Pending); inviter '
        'roster includes him (Add committed at creation)',
        (tester) async {
      // ------------------------------------------------------------------
      // Step 1 — Gate on Dave's KeyPackage landing on the relay before
      // Alice calls `fetchMemberKeypackage`. `bootstrap` publishes it
      // synchronously but the strfry session-start adds a small latency
      // window; `waitForKeyPackage` covers it with a 30 s budget.
      // ------------------------------------------------------------------
      await waitForKeyPackage(
        relay: fe2Relay,
        authorPubkeyHex: fe2Dave.pubkeyHex,
      );

      // ------------------------------------------------------------------
      // Step 2 — Alice fetches Dave's KeyPackage and creates a 2-member
      // circle. `createCircle` returns the circle metadata AND a
      // gift-wrapped Welcome for Dave. We publish Dave's gift-wrap to the
      // relay so the scenario mirrors production: the gift-wrap DOES
      // reach Dave, and Dave simply never acts on it.
      //
      // `fetchMemberKeypackage` lives on `RelayManagerFfi` (not
      // `CircleManagerFfi`), so we create a dedicated relay-manager
      // instance here. It is scoped to this test and not reused.
      // ------------------------------------------------------------------
      final relayManager = await RelayManagerFfi.newInstance();
      final daveKp = await relayManager.fetchMemberKeypackage(
        pubkey: fe2Dave.pubkeyHex,
      );
      if (daveKp == null) {
        throw StateError(
          '[FE-2] fetchMemberKeypackage returned null for Dave — '
          "Dave's KeyPackage was not found on the relay.",
        );
      }

      final aliceSecret = await fe2Alice.user.getSecretBytes();
      final CircleCreationResultFfi creationResult;
      try {
        creationResult = await fe2Alice.user.circleManager.createCircle(
          identitySecretBytes: aliceSecret,
          members: <MemberKeyPackageFfi>[daveKp],
          name: 'FE-2 Circle',
          circleType: 'location_sharing',
          relays: <String>[fe2Relay.url],
          // Dave (a SyntheticUser) advertises no inbox/NIP-65 relays, so the
          // Welcome-delivery cascade has no recipient relay to resolve and
          // fails closed with MissingWelcomeRelays unless the admin supplies a
          // fallback. Pass the admin's own inbox relay (the hermetic relay) —
          // exactly what the production admin flow does — so createCircle
          // resolves Dave's recipient relays and returns his gift-wrap, which
          // this test then publishes manually below.
          creatorFallbackRelays: <String>[fe2Relay.url],
        );
      } finally {
        for (var i = 0; i < aliceSecret.length; i++) {
          aliceSecret[i] = 0;
        }
      }

      // Publish Dave's gift-wrap so the relay `firstWhere` below is
      // non-vacuous. Without publishing, Dave would never have a real
      // gift-wrap to "ignore", and the invite-ignore assertion would pass
      // trivially without exercising the processGiftWrappedInvitation path.
      final daveWelcome = creationResult.welcomeEvents.firstWhere(
        (e) => e.recipientPubkey.toLowerCase() ==
            fe2Dave.pubkeyHex.toLowerCase(),
        orElse: () => throw StateError(
          '[FE-2] createCircle did not produce a gift-wrap for Dave. '
          'Regression in the Rust-side gift-wrap generation.',
        ),
      );
      final (daveWelcomeAccepted, daveWelcomeMsg) =
          await fe2Relay.publishAndAwaitOk(daveWelcome.eventJson);
      if (!daveWelcomeAccepted) {
        throw StateError(
          '[FE-2] relay rejected the gift-wrap for Dave: $daveWelcomeMsg',
        );
      }

      // ------------------------------------------------------------------
      // Step 3 — Wait for Dave's gift-wrap to be observable on the relay
      // before Dave "processes" it. Makes the ignore non-vacuous: Dave's
      // processGiftWrappedInvitation succeeds because the gift-wrap is
      // genuinely on the relay (same production path).
      // ------------------------------------------------------------------
      final daveGiftWrap = await fe2Relay.firstWhere(
        filter: <String, dynamic>{
          'kinds': <int>[1059],
          '#p': <String>[fe2Dave.pubkeyHex],
          'limit': 5,
        },
        timeout: _giftWrapDeadline,
      );

      // ------------------------------------------------------------------
      // Step 4 — Dave processes the gift-wrap (decrypts the Welcome,
      // stores the pending invitation in MDK) then DELIBERATELY does NOT
      // call `acceptInvitation`. Production UI equivalent: the user opens
      // InvitationsPage but never taps Accept.
      // ------------------------------------------------------------------
      final giftWrapJson = jsonEncode(daveGiftWrap.raw);
      final daveSecret = await fe2Dave.user.getSecretBytes();
      final InvitationFfi? pendingInvitation;
      try {
        pendingInvitation =
            await fe2Dave.user.circleManager.processGiftWrappedInvitation(
          identitySecretBytes: daveSecret,
          giftWrapEventJson: giftWrapJson,
        );
      } finally {
        for (var i = 0; i < daveSecret.length; i++) {
          daveSecret[i] = 0;
        }
      }

      // processGiftWrappedInvitation MUST return a non-null invitation
      // (the gift-wrap is freshly published and well-formed). A null here
      // means the gift-wrap failed to decrypt — regression in the NIP-59
      // gift-wrap path or Dave's key derivation, NOT the ignore path.
      expect(
        pendingInvitation,
        isNotNull,
        reason:
            '[FE-2] processGiftWrappedInvitation returned null for Dave. '
            'The gift-wrap was freshly published and addressed to the '
            'correct pubkey; a null result signals a regression in the '
            'NIP-59 decrypt path, not the invite-ignore scenario.',
      );

      // ------------------------------------------------------------------
      // Step 5 — Assert the non-acceptance invariants.
      //
      // (a) Dave's invitation must remain PENDING — he processed the
      //     gift-wrapped Welcome but never accepted it — and his circle
      //     must NOT appear in the accepted (visible) set.
      //
      // (b) Alice's MLS roster contains BOTH herself and Dave (2 members).
      //     `create_circle(members: [Dave])` commits the Add at group
      //     *creation*: MDK `create_group` admits Dave into Alice's ratchet
      //     tree immediately and returns his Welcome as the artifact he needs
      //     to catch up. Whether Dave ever processes that Welcome has no
      //     effect on Alice's local roster — he is a member of HER view from
      //     creation. "Dave ignored the invite" is therefore proven by the
      //     invitee-side checks in part (a) (his membership stays Pending and
      //     his circle never enters the visible/Accepted set), NOT by Alice's
      //     roster count. (Matches whitenoise-rs `case_create_group_success`:
      //     members == invitees + creator.)
      // ------------------------------------------------------------------

      // (a) Dave's pending invitation.
      //
      // `getCircle` is deliberately NOT used here. It resolves the member
      // roster through MDK's *active* group store, which holds no group for
      // a processed-but-unaccepted Welcome: MDK keeps it as a `Pending`
      // staged welcome until `acceptInvitation` runs `into_group`, so
      // `getCircle` → `getMembers` returns "group not found". Production
      // observes pending state through `getPendingInvitations()` — the same
      // API the InvitationsPage uses (see invitation_provider.dart) — so the
      // test asserts through that door too.
      final davePending =
          await fe2Dave.user.circleManager.getPendingInvitations();
      final daveInvites = davePending
          .where(
            (i) => listEquals(i.mlsGroupId, pendingInvitation!.mlsGroupId),
          )
          .toList();
      expect(
        daveInvites,
        hasLength(1),
        reason:
            "[FE-2] Dave's processed-but-unaccepted invitation must appear "
            'exactly once in getPendingInvitations(). The core filters that '
            'list to Pending-status memberships, so an entry here proves '
            'Dave processed the gift-wrap yet never accepted — the same '
            'guarantee as the old membershipStatus=="pending" check, via the '
            'API production actually uses for pending invites.',
      );
      // The pending invitation must report at least the inviter (>= 1
      // member). This exercises the Welcome-derived member_count path and
      // guards a regression that drops the embedded NostrGroupData count.
      expect(
        daveInvites.single.memberCount,
        greaterThanOrEqualTo(1),
        reason:
            '[FE-2] the pending invitation reports '
            '${daveInvites.single.memberCount} member(s); expected >= 1 (the '
            'inviter at minimum). A 0 here means the Welcome member-count '
            'parse regressed.',
      );
      // Symmetric "did not auto-accept" invariant: Dave's circle must be
      // absent from the visible set. `getVisibleCircles` admits Accepted
      // memberships only (is_visible()), so a hit here would catch an
      // auto-accept that the pending-list check alone could miss.
      final daveVisible =
          await fe2Dave.user.circleManager.getVisibleCircles();
      final daveAccepted = daveVisible.where(
        (c) => listEquals(c.circle.mlsGroupId, pendingInvitation!.mlsGroupId),
      );
      expect(
        daveAccepted,
        isEmpty,
        reason:
            "[FE-2] Dave's circle must not appear in the visible (Accepted) "
            'set — the invite-ignore path must never auto-accept. '
            'acceptInvitation was never called, so the circle must stay out '
            'of the accepted set entirely.',
      );

      // (b) Alice's roster: exactly 2 members (herself + Dave). Alice
      //     committed the Add at circle creation, so Dave is in her tree even
      //     though he never joined his own view (proven in part (a)).
      final aliceMembers = await fe2Alice.user.circleManager.getMembers(
        mlsGroupId: creationResult.circle.mlsGroupId,
      );
      expect(
        aliceMembers.length,
        equals(2),
        reason:
            '[FE-2] the inviter group has ${aliceMembers.length} member(s); '
            'expected exactly 2 (the creator + the invited Dave). '
            '`create_circle` commits the Add at creation, so the invitee is '
            "in the inviter's MLS roster regardless of whether he ever "
            'accepts the Welcome. Non-join is asserted on the invitee side '
            'in part (a).',
      );
      final aliceMemberPubkeys =
          aliceMembers.map((m) => m.pubkey.toLowerCase()).toSet();
      expect(
        aliceMemberPubkeys,
        unorderedEquals(<String>[
          fe2Alice.pubkeyHex.toLowerCase(),
          fe2Dave.pubkeyHex.toLowerCase(),
        ]),
        reason:
            '[FE-2] the inviter roster must be exactly the creator '
            '(${_redactPk(fe2Alice.pubkeyHex)}) and the invited Dave '
            '(${_redactPk(fe2Dave.pubkeyHex)}). Got '
            '${aliceMemberPubkeys.map(_redactPk).toList()}.',
      );

      debugPrint(
        '[FE-2] invite-ignore OK — Dave has ${daveInvites.length} pending '
        'invitation(s) and 0 accepted; Alice has ${aliceMembers.length} '
        'member(s) (herself + the invited-but-unjoined Dave).',
      );
    });
  });
}

// =============================================================================
// PHASE 2a helpers — Alice creates a 2-member circle (Alice + Bob) via UI
// =============================================================================

/// Creates a 2-member circle (Alice + Bob) through the production UI and
/// returns the ephemeral pubkey of the init kind-445 commit.
///
/// Carol's KeyPackage is already published to the relay (from setUpAll) but
/// she is intentionally NOT invited at creation time. The post-creation
/// add-member flow in Phase 2b invites her, which is the new behaviour this
/// test validates end-to-end.
///
/// The returned init-commit pubkey is the `pubkey` field from the init
/// kind-445 commit captured off the relay. It is used in Phase 2b to assert
/// that the Add-commit carries a DISTINCT ephemeral key per MIP-03 rule 2
/// (ephemeral key per group message — reuse would let the relay link events).
Future<String> _aliceCreatesTwoMemberCircle({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required SyntheticUser bob,
}) async {
  // Bob's KeyPackage was published synchronously in setUpAll. Assert its
  // availability before Alice opens CreateCirclePage so we never race the
  // relay's session-start latency.
  await waitForKeyPackage(
    relay: ctx.relay,
    authorPubkeyHex: bob.pubkeyHex,
  );

  // Open Bob's gift-wrap subscription BEFORE Alice taps Create so we never
  // miss the event. NIP-59 gift-wraps use ephemeral outer keys, so we filter
  // by recipient `#p` tag rather than by author.
  final bobGiftWrapFuture = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: bob.pubkeyHex,
    timeout: _giftWrapDeadline,
  );

  // Expand the draggable bottom sheet to bring the empty-state CTA into the
  // viewport. The retry-aware helper avoids the velocity-tracker flake the
  // synthetic-drag pattern is prone to on slow CI emulators.
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.byKey(WidgetKeys.circlesCreateCta),
  );
  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  // pumpUntilFound, not pumpAndSettle. MapShell stays in the Navigator's
  // back stack while CreateCirclePage is on top, and MapShell's periodic
  // timers continue scheduling frames — pumpAndSettle would never see an
  // empty frame queue and would hang on its internal 10-minute fallback.
  await pumpUntilFound(
    tester,
    find.byType(CreateCirclePage),
    description: 'CreateCirclePage after tapping Create Circle CTA',
  );

  // Member selection — enter Bob's npub only. Carol will be added later
  // via the AddMemberPage UI in Phase 2b.
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    bob.npub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  // Wait for the Continue button to be tappable (enabled state flips once
  // Bob's npub validates against the relay's KP fetch).
  await pumpUntilCondition(
    tester,
    () {
      final btn = find.byKey(WidgetKeys.createCircleContinue);
      if (btn.evaluate().isEmpty) return false;
      final widget = tester.widget(btn);
      if (widget is FilledButton) return widget.onPressed != null;
      // Defensive: if the underlying widget type changes, keep waiting so
      // the 60s timeout surfaces a clear failure rather than silently
      // tapping a possibly-disabled button.
      return false;
    },
    description: "createCircleContinue enabled after Bob's npub validates",
    timeout: const Duration(seconds: 60),
  );

  await tester.tap(find.byKey(WidgetKeys.createCircleContinue));
  await pumpUntilFound(
    tester,
    find.byType(NameCirclePage),
    description: 'NameCirclePage after Continue tap',
  );
  await tester.enterText(
    find.byKey(WidgetKeys.circleNameInput),
    _circleName,
  );
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  // `_createCircle` awaits the relay publish of every Welcome BEFORE it
  // auto-selects the new circle and pops NameCirclePage + CreateCirclePage
  // (the pops run synchronously, right after the auto-select). Gate on
  // NameCirclePage leaving the tree: its disappearance proves the flow
  // finished (the Welcome published, the new circle was auto-selected, and
  // we are back on the map shell).
  await pumpUntilGone(
    tester,
    find.byType(NameCirclePage),
    timeout: const Duration(seconds: 60),
    description: 'NameCirclePage popping after Create Circle completes',
  );

  // Smoke-check: the circle selector must show the newly created circle as
  // the active selection. Read the production circlesProvider to obtain the
  // circle's stable nostrGroupId hex so the finder does not couple to the
  // display string "$_circleName", which is brittle to truncation.
  final smokeCircles = await ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  ).read(circlesProvider.future);
  expect(
    smokeCircles,
    isNotEmpty,
    reason:
        'circlesProvider must have at least one circle immediately '
        'after Create Circle returns to MapShell.',
  );
  final familyHex = smokeCircles.first.nostrGroupId
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.circleSelectorActive(familyHex)),
    description: 'circle selector active row for the newly created circle',
  );
  expect(
    find.byKey(WidgetKeys.circleSelectorActive(familyHex)),
    findsOneWidget,
    reason:
        'After Create Circle returns to MapShell, the circle selector '
        'trigger row must display the newly created circle as the '
        'active selection (keyed by nostrGroupId, not display name).',
  );

  // Bob's gift-wrap must have landed; without it his
  // acceptInvitationViaRelay would hang on the firstWhere lookup.
  await bobGiftWrapFuture;

  // Capture the init kind-445 commit from the relay. Opened AFTER we wait for
  // the gift-wrap (guaranteeing the circle-creation flow published its commit
  // to the relay). The `#h` filter routes to this circle only.
  //
  // We use collectN with a short timeout to grab at least one commit; strfry
  // serves stored events immediately, so the committed init event is already
  // present once the gift-wrap landed (gift-wrap publish happens after the
  // commit publish in the production create-circle flow).
  final initCommits = await ctx.relay.collectN(
    count: 5,
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      '#h': <String>[familyHex],
      'limit': 5,
    },
    timeout: const Duration(seconds: 10),
  );
  if (initCommits.isEmpty) {
    throw StateError(
      '[e2e_combined:alice] no kind-445 commit found for the new circle '
      '(nostrGroupIdHex: $familyHex) after Phase 2a. The create-circle '
      'flow must publish the init commit to the relay before returning.',
    );
  }
  // There should be exactly one init commit; take the first (earliest
  // created_at) in case the publisher emitted more than one.
  final initCommit = initCommits.reduce(
    (a, b) => a.createdAt <= b.createdAt ? a : b,
  );
  final initCommitPubkey = initCommit.pubkey;

  debugPrint(
    '[e2e_combined:alice] PHASE 2a complete (2-member circle, '
    'initCommitPubkey=${_redactPk(initCommitPubkey)}).',
  );
  return initCommitPubkey;
}

// =============================================================================
// PHASE 2b helpers — Alice adds Carol via the AddMemberPage UI
// =============================================================================

/// Snapshots the ids of every kind-1059 gift-wrap currently addressed to
/// [recipientPubkeyHex] on [relay].
///
/// kind-1059 gift-wraps carry a NIP-59 randomised `created_at` (back-dated by
/// up to 48 h; see `wrap_welcome` in haven-core), so a wall-clock `since`
/// cursor cannot tell a freshly-published Welcome from an old one. Capturing
/// the pre-existing event ids instead lets a later fetch isolate the
/// gift-wraps published during a membership change purely by id, independent
/// of their back-dated timestamps.
///
/// The matching events are already stored on the hermetic relay, so the
/// `collectN` timeout is only a safety net for a slow round-trip — the
/// over-sized `count` never completes early, it just drains what is present.
Future<Set<String>> _giftWrapIdSnapshot(
  TestRelay relay,
  String recipientPubkeyHex,
) async {
  final existing = await relay.collectN(
    count: 64,
    filter: <String, dynamic>{
      'kinds': const <int>[1059],
      '#p': <String>[recipientPubkeyHex],
      'limit': 64,
    },
    timeout: const Duration(seconds: 5),
  );
  return existing.map((event) => event.id).toSet();
}

/// Drives Alice's AddMemberPage UI to add Carol to the existing circle, then
/// asserts relay artifacts and epoch deltas before returning Carol's accepted
/// [CircleWithMembersFfi].
///
/// ## What is asserted here
///
/// ### Relay artifacts (before Carol accepts)
///
/// - Exactly 1 new kind-1059 gift-wrap addressed to Carol (#p=Carol's pubkey)
///   appearing AFTER the init commit — proves the Welcome was gift-wrapped and
///   delivered to Carol's inbox relay.
/// - Exactly 1 new kind-445 Add commit with #h==nostr_group_id, `created_at`
///   after the init commit, and a DISTINCT ephemeral pubkey (not equal to the
///   init commit pubkey) — proves MIP-03 fresh-key-per-message.
/// - The Add commit carries NO `expiration` tag — expiration belongs on the
///   gift-wrapped Welcome, not on the MLS commit message.
/// - The `#h` tag contains the nostr_group_id, never the real MLS group id
///   (group-id privacy rule, CLAUDE.md §4).
///
/// ### Epoch deltas
///
/// - Alice's epoch advanced by exactly 1 from [epochBeforeAdd] to
///   epochBeforeAdd+1 — the Add commit finalized on Alice's side.
/// - After Bob drains the Add commit from the relay, Bob's epoch also
///   advanced by exactly 1 from [bobEpochBeforeAdd] — existing-member epoch
///   advance confirmed via the on-wire path.
///
/// The epoch counter lives inside the NIP-44-encrypted kind-445 payload and
/// is NOT visible on the wire. The `groupEpochForTest` FFI method reads it
/// from each peer's own MDK instance — this is the only way to assert key
/// rotation without decrypting group messages.
Future<CircleWithMembersFfi> _aliceAddsCarolViaUi({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required SyntheticUser bob,
  required SyntheticUser carol,
  required String initCommitPubkey,
  required int epochBeforeAdd,
  required int bobEpochBeforeAdd,
  required CircleWithMembersFfi bobCircle,
}) async {
  // Record the current time to use as `since` for the kind-445 relay
  // subscriptions we open just before driving the UI. A wall-clock `since`
  // keeps stale init commits from satisfying our `firstWhere` waits vacuously.
  //
  // `since` is valid for kind-445 ONLY: MLS commits carry a real `created_at`.
  // kind-1059 gift-wraps are NIP-59 back-dated (random offset up to 48 h; see
  // `wrap_welcome`), so a wall-clock `since` would exclude the freshly
  // published — but back-dated — Welcome. The gift-wrap waits below use
  // event-id novelty against a pre-add snapshot instead.
  final sinceSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final nostrGroupIdHex = _hexLower(bobCircle.circle.nostrGroupId);
  final mlsGroupId = bobCircle.circle.mlsGroupId;
  final mlsGroupIdHex = _hexLower(bobCircle.circle.mlsGroupId);

  // Guard: the group-id scan below is only meaningful when the two IDs
  // differ. Equal values would make the scan vacuous and mask an
  // id-aliasing bug in the Rust layer.
  expect(
    mlsGroupIdHex,
    isNot(equals(nostrGroupIdHex)),
    reason:
        'PHASE 2b group-id check: the real MLS group id must differ from '
        'the nostr_group_id. Equal values would make the group-id privacy '
        'scan vacuous (id-aliasing regression in the Rust layer).',
  );

  // Snapshot the kind-1059 gift-wraps already on the relay for Carol and Bob
  // BEFORE driving the UI. Because gift-wrap `created_at` is NIP-59
  // back-dated, a wall-clock `since` cannot distinguish a Welcome published
  // during this add from an older one; event-id novelty can. Carol is brand
  // new to the circle, so her snapshot is expected empty; Bob already holds
  // his Phase-2a Welcome, which anchors the "no re-welcome on add" negative
  // control below. Nothing publishes a new gift-wrap until the UI gesture, so
  // these snapshots are stable.
  final preAddCarolWrapIds = await _giftWrapIdSnapshot(
    ctx.relay,
    carol.pubkeyHex,
  );
  final preAddBobWrapIds = await _giftWrapIdSnapshot(ctx.relay, bob.pubkeyHex);

  // Open Carol's gift-wrap subscription and the Add-commit subscription
  // BEFORE driving the UI — race-free: any event published during the UI
  // gestures below will be buffered by the live subscription. Carol's wait
  // matches by event-id novelty (not `since`) for the back-dating reason
  // above; the kind-445 Add-commit wait keeps `since` (commits are not
  // back-dated) and additionally excludes location updates (see the selector
  // note below).
  final carolGiftWrapFuture = ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[1059],
      '#p': <String>[carol.pubkeyHex],
      'limit': 10,
    },
    matcher: (event) => !preAddCarolWrapIds.contains(event.id),
    timeout: _giftWrapDeadline,
  );
  // The kind-445 stream for this group is NOT commits-only: location updates
  // are also kind-445 with the same #h tag, so one can land inside this
  // `since` window and race the Add commit. Location updates carry a NIP-40
  // `expiration` tag; an MLS commit MUST NOT (a NIP-40 relay stops serving
  // expired events, which would break epoch catch-up for late/offline peers —
  // see haven-core/SECURITY.md and the Rust
  // `*_evolution_event_has_no_expiration_tag` tests). Select the Add commit by
  // that protocol invariant so a racing location update is never mistaken for
  // it.
  final addCommitFuture = ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      '#h': <String>[nostrGroupIdHex],
      'since': sinceSecs,
      'limit': 10,
    },
    matcher: (event) => event.tag('expiration') == null,
    timeout: _giftWrapDeadline,
  );

  // -------------------------------------------------------------------
  // Drive Alice's UI: circle-details sheet → Add member → AddMemberPage.
  //
  // The circle is already selected from Phase 2a. The details button is
  // visible in the collapsed trigger row; we do not need to re-expand the
  // sheet to reach it (it sits in the circle-selector header, not the
  // bottom-sheet content area).
  // -------------------------------------------------------------------
  final detailsButton = find.byKey(WidgetKeys.circleDetailsButton);
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        'PHASE 2b: the circle-details info button must be visible in the '
        'circle selector header after Phase 2a created the circle.',
  );
  await tester.tap(detailsButton);
  // Modal opens on top of MapShell — wait for the "Add member" CTA to be
  // findable rather than pumpAndSettle (MapShell's periodic timers keep
  // the frame queue non-empty even while the modal is up).
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.addMemberCta),
    description: 'addMemberCta after tapping circle-details info button',
  );

  // Tap "Add member" and wait for AddMemberPage to mount.
  await tester.tap(find.byKey(WidgetKeys.addMemberCta));
  await pumpUntilFound(
    tester,
    find.byType(AddMemberPage),
    description: 'AddMemberPage after tapping addMemberCta',
  );

  // Enter Carol's npub into the search field. The UI is the same
  // MemberSearchBar + PendingMemberTile picker used in CreateCirclePage,
  // sharing the WidgetKeys.memberSearchInput key.
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    carol.npub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);

  // Wait for the confirm button to become enabled (Carol's npub validates
  // once fetchKeyPackage returns a KP — Carol's KP was published in setUpAll).
  await pumpUntilCondition(
    tester,
    () {
      final btn = find.byKey(WidgetKeys.addMemberConfirm);
      if (btn.evaluate().isEmpty) return false;
      final widget = tester.widget(btn);
      if (widget is FilledButton) return widget.onPressed != null;
      return false;
    },
    description: "addMemberConfirm enabled after Carol's npub validates",
    timeout: const Duration(seconds: 60),
  );

  // Tap confirm — triggers _onAddMembers which calls addMember → add commit
  // + gift-wrap, then pops AddMemberPage on success.
  await tester.tap(find.byKey(WidgetKeys.addMemberConfirm));
  // AddMemberPage pops on success; wait for it to leave the tree.
  await pumpUntilGone(
    tester,
    find.byType(AddMemberPage),
    timeout: const Duration(seconds: 60),
    description: 'AddMemberPage popping after Add Member completes',
  );

  // -------------------------------------------------------------------
  // Assert relay artifacts — Carol's gift-wrap and the Add commit.
  // -------------------------------------------------------------------
  final carolGiftWrap = await carolGiftWrapFuture;
  final addCommit = await addCommitFuture;

  // 1. Carol's gift-wrap must be addressed to her pubkey via #p.
  final pTag = carolGiftWrap.tag('p');
  expect(
    pTag,
    isNotNull,
    reason:
        "PHASE 2b: Carol's kind-1059 gift-wrap must carry a #p tag "
        'with her pubkey.',
  );
  expect(
    pTag!.length >= 2 &&
        pTag[1].toLowerCase() == carol.pubkeyHex.toLowerCase(),
    isTrue,
    reason:
        "PHASE 2b: Carol's gift-wrap #p tag must equal her pubkey hex. "
        'Got: $pTag',
  );

  // 2. The Add commit must carry #h == nostr_group_id (group-id privacy).
  final hTag = addCommit.tag('h');
  expect(
    hTag,
    isNotNull,
    reason:
        'PHASE 2b: the Add kind-445 commit must carry an #h tag.',
  );
  expect(
    hTag!.length >= 2 && hTag[1].toLowerCase() == nostrGroupIdHex,
    isTrue,
    reason:
        'PHASE 2b: the Add commit #h tag must equal the nostr_group_id. '
        'Got: $hTag, expected: $nostrGroupIdHex (Security Rule 4).',
  );

  // 3. The Add commit must have a LATER created_at than the init commit.
  //    (Uses sinceSecs which was captured at the moment we entered Phase 2b.)
  expect(
    addCommit.createdAt >= sinceSecs,
    isTrue,
    reason:
        'PHASE 2b: the Add commit (created_at=${addCommit.createdAt}) must '
        'be after the Phase 2b start time (sinceSecs=$sinceSecs). An earlier '
        'commit would mean we matched a stale init commit instead of the Add.',
  );

  // 4. DISTINCT ephemeral pubkey — MIP-03 fresh-key-per-message.
  //    The Add commit must be signed by a different ephemeral key than the
  //    init commit captured in Phase 2a.
  expect(
    addCommit.pubkey.toLowerCase(),
    isNot(equals(initCommitPubkey.toLowerCase())),
    reason:
        'PHASE 2b: the Add commit must be signed by a DISTINCT ephemeral '
        'key (MIP-03 rule 2). initCommit=${_redactPk(initCommitPubkey)}, '
        'addCommit=${_redactPk(addCommit.pubkey)}.',
  );

  // 5. The Add commit carries NO `expiration` tag — expiration belongs on
  //    location updates (auto-cleanup) and the gift-wrapped Welcome, never on
  //    an MLS commit (a NIP-40 relay stops serving expired events, breaking
  //    epoch catch-up for late/offline peers). This invariant is enforced by
  //    construction at the `addCommitFuture` selector above (it matches only
  //    the no-`expiration` kind-445, so a commit that wrongly stamped a TTL
  //    would leave no commit-shaped event and fail this phase via timeout) and
  //    is unit-tested in haven-core
  //    (`add_members_evolution_event_has_no_expiration_tag`). Re-asserting
  //    `isNull` on the already-filtered event would be vacuous, so it is
  //    intentionally omitted here.

  // 6. The real MLS group id must not appear in any tag of the Add commit
  //    (group-id privacy, CLAUDE.md Security Rule 4).
  for (final tag in addCommit.tags) {
    for (final value in tag) {
      expect(
        value.toLowerCase().contains(mlsGroupIdHex),
        isFalse,
        reason:
            'PHASE 2b: the real MLS group id leaked into the Add commit '
            'tag $tag (Security Rule 4). Only the nostr_group_id may '
            'appear in #h tags.',
      );
    }
  }

  // -------------------------------------------------------------------
  // 7. WELCOME CARDINALITY — exactly ONE new gift-wrap to Carol and ZERO
  //    to Bob (scoped to `sinceSecs` so only Phase 2b events are counted).
  //
  // Catches a regression `firstWhere` above would miss: "re-welcome every
  // member on add" — Bob would receive a spurious kind-1059 (privacy
  // violation: an existing member must never be re-welcomed when a NEW
  // member is added). kind-1059 is unambiguous (gift-wraps only), so the
  // count is reliable.
  //
  // We deliberately do NOT count kind-445 to assert "exactly one Add
  // commit": kind-445 is overloaded — MLS commits AND encrypted location
  // messages share the kind and the #h tag and are indistinguishable on
  // the wire, so a relay count would be flaky once locations flow. Commit
  // cardinality is instead proven cryptographically by the epoch-delta
  // asserts below: a duplicate/extra commit would advance Alice to
  // epochBeforeAdd+2 (and Bob likewise), failing the exact "+1" checks.
  //
  // `collectN(count: 2, …)` drives the subscription long enough to surface
  // a second event IF one exists; on timeout it resolves with whatever was
  // collected and the length assertion catches the wrong count explicitly.
  // -------------------------------------------------------------------

  // 7a. Exactly ONE NEW kind-1059 addressed to Carol during the add.
  //     Isolated by event-id novelty (not `since`) because gift-wrap
  //     `created_at` is NIP-59 back-dated. `count: 2` over-fetches so a
  //     duplicate-welcome regression surfaces as a second new event.
  final carolGiftWrapsRaw = await ctx.relay.collectN(
    count: 2,
    filter: <String, dynamic>{
      'kinds': const <int>[1059],
      '#p': <String>[carol.pubkeyHex],
      'limit': 10,
    },
    timeout: const Duration(seconds: 8),
  );
  final carolGiftWraps = carolGiftWrapsRaw
      .where((event) => !preAddCarolWrapIds.contains(event.id))
      .toList();
  expect(
    carolGiftWraps.length,
    equals(1),
    reason:
        'PHASE 2b cardinality: exactly ONE new kind-1059 addressed to Carol '
        'must be published during the add. Got ${carolGiftWraps.length} new '
        '(of ${carolGiftWrapsRaw.length} total on the relay). Multiple '
        'gift-wraps would signal a duplicate-welcome regression.',
  );

  // 7b. ZERO NEW kind-1059 addressed to Bob during the add.
  //     Existing members must NOT be re-welcomed when a new peer is added —
  //     re-welcoming leaks Bob's past membership visibility to any future
  //     observer who correlates #p tags.
  //
  //     Subtract Bob's pre-add snapshot by event id rather than filtering on
  //     `since`: a spurious re-welcome would be NIP-59 back-dated exactly like
  //     Bob's legitimate Phase-2a Welcome and would slip under a wall-clock
  //     cursor (the old `since` form made this assertion vacuous). `count: 2`
  //     over-fetches past Bob's single existing Welcome so a re-welcome is
  //     actually observable.
  final bobGiftWrapsRaw = await ctx.relay.collectN(
    count: 2,
    filter: <String, dynamic>{
      'kinds': const <int>[1059],
      '#p': <String>[bob.pubkeyHex],
      'limit': 10,
    },
    timeout: const Duration(seconds: 5),
  );
  final bobGiftWraps = bobGiftWrapsRaw
      .where((event) => !preAddBobWrapIds.contains(event.id))
      .toList();
  expect(
    bobGiftWraps,
    isEmpty,
    reason:
        'PHASE 2b cardinality: ZERO new kind-1059 addressed to Bob must be '
        'published during the add. Got ${bobGiftWraps.length} new (of '
        '${bobGiftWrapsRaw.length} total on the relay). Existing members must '
        'never be re-welcomed when a new member is added (correctness + '
        'privacy).',
  );

  // (Add-commit cardinality is asserted via the epoch-delta checks below,
  //  not by counting kind-445 on the relay — see the section note above.)

  debugPrint(
    '[e2e_combined:alice] PHASE 2b relay assertions OK — '
    'carol gift-wrap ${_redactPk(carolGiftWrap.id)}, '
    'add commit ${_redactPk(addCommit.id)} '
    'distinct ephemeral key, no expiration tag, no MLS group id leakage, '
    'welcome cardinality OK (1 carol gift-wrap, 0 bob gift-wraps; '
    'commit cardinality via epoch delta).',
  );

  // -------------------------------------------------------------------
  // Assert epoch delta — Alice's epoch must have advanced by exactly 1.
  // -------------------------------------------------------------------
  // Poll briefly: AddMemberPage already awaited the finalize before popping,
  // so the epoch should be updated immediately. We poll defensively for up to
  // 10s to cover any async flush between the FFI finalize and the in-process
  // MDK state being queryable.
  final epochAfterAdd = await _pollUntil<int>(
    describe:
        "Alice's epoch advancing by 1 after the Add commit (expected "
        '${epochBeforeAdd + 1})',
    probe: () => _aliceEpochForTest(tester, mlsGroupId),
    satisfied: (epoch) => epoch == epochBeforeAdd + 1,
    budget: const Duration(seconds: 10),
    interval: const Duration(milliseconds: 500),
  );
  expect(
    epochAfterAdd,
    equals(epochBeforeAdd + 1),
    reason:
        "PHASE 2b: Alice's MLS epoch must advance by exactly 1 after "
        'the Add commit finalizes. Before=$epochBeforeAdd, '
        'after=$epochAfterAdd. An epoch delta != 1 means either the '
        "commit did not finalize on Alice's side or MDK advanced by "
        'an unexpected number of steps.',
  );
  debugPrint(
    '[e2e_combined:alice] PHASE 2b epoch OK — '
    'alice: $epochBeforeAdd → $epochAfterAdd (+1)',
  );

  // -------------------------------------------------------------------
  // Assert Bob's epoch — after he drains the Add commit, his epoch must
  // also advance by exactly 1.
  //
  // Bob draining the Add commit is the existing-member epoch advance
  // confirmed via the on-wire path: the Add commit is a real kind-445 on
  // the relay, Bob processes it through the same decrypt path production
  // uses, and his MDK advances.
  // -------------------------------------------------------------------
  await _pollUntil<int>(
    describe:
        "Bob's epoch advancing by 1 after draining the Add commit "
        '(expected ${bobEpochBeforeAdd + 1})',
    probe: () async {
      // Drain the Add commit (and any surrounding events) via Bob's normal
      // decrypt path. Pass `since` anchored to our Phase 2b start time so
      // Bob only processes the Add commit and later events — not the init
      // commit he already applied via acceptInvitationViaRelay.
      await bob.drainPendingCommits(
        relay: ctx.relay,
        circle: bobCircle,
        since: DateTime.fromMillisecondsSinceEpoch(sinceSecs * 1000),
      );
      return bob.currentEpoch(mlsGroupId);
    },
    satisfied: (epoch) => epoch == bobEpochBeforeAdd + 1,
  );
  final bobEpochAfterAdd = await bob.currentEpoch(mlsGroupId);
  expect(
    bobEpochAfterAdd,
    equals(bobEpochBeforeAdd + 1),
    reason:
        "PHASE 2b: Bob's MLS epoch must advance by exactly 1 after he "
        'processes the Add commit from the relay. '
        'Before=$bobEpochBeforeAdd, after=$bobEpochAfterAdd. '
        'An epoch delta != 1 signals that the Add commit was not '
        "routed to the relay's #h index or Bob's "
        'drainPendingCommits did not process it.',
  );
  debugPrint(
    '[e2e_combined:bob] PHASE 2b epoch OK — '
    'bob: $bobEpochBeforeAdd → $bobEpochAfterAdd (+1)',
  );

  debugPrint(
    '[e2e_combined] PHASE 2b complete (Carol added via AddMemberPage).',
  );

  // Now Carol can accept. Return carolCircle from acceptInvitationViaRelay.
  final accepted = await carol.acceptInvitationViaRelay(
    relay: ctx.relay,
  );
  return accepted;
}

// =============================================================================
// PHASE 3b helpers — Carol accepts; epoch cross-check; KP republish assertion
// =============================================================================

/// Asserts the post-add state on all three peers and the behavioral
/// forward-secrecy cross-check for Carol.
///
/// After Carol accepts:
/// 1. All three peers' MDK member sets must contain [Alice, Bob, Carol].
/// 2. Carol's epoch == Alice's current epoch (joined at the post-Add epoch).
/// 3. A fresh KeyPackage authored by Carol appears on the relay (KP-consumed-
///    then-rotated on accept — production `keyPackagePublisherProvider` fires
///    via `startJoinerWatch`).
/// 4. **Behavioral forward-secrecy cross-check** (epoch boundary matters):
///    - Alice publishes a POST-ADD location (via `locationPublisherProvider`).
///    - Carol CAN decrypt the post-add location (she's a member from the Add
///      epoch onward).
///    - Carol CANNOT decrypt [preAddLocationEvent] — Bob's location published
///      at the init epoch (2-member phase, before the Add commit). Carol joined
///      at epochBeforeAdd+1 via the Add Welcome; MDK never delivered the
///      epoch-N exporter secret to her, so the decrypt returns null rather than
///      coordinates. This is the MLS forward-secrecy / epoch-boundary guarantee
///      for added members.
///
/// This is the behavioral proof that the Add advanced the epoch and gated
/// key access — pure relay + MDK state, no widget assertions.
Future<void> _carolAcceptsAndEpochCheck({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required SyntheticUser carol,
  required SyntheticUser bob,
  required CircleWithMembersFfi carolCircle,
  required List<int> mlsGroupId,
  required int epochBeforeAdd,
  required TestRelayEvent preAddLocationEvent,
}) async {
  // carolCircle was returned by carol.acceptInvitationViaRelay in Phase 2b.
  // Assert all three peers' member sets match [Alice, Bob, Carol].
  _assertCircleHasMembers(
    label: 'carol (after joining)',
    circle: carolCircle,
    expectedPubkeyHexes: <String>[
      _alicePubkeyHex(),
      bob.pubkeyHex,
      carol.pubkeyHex,
    ],
  );

  // Bob's circle after he processed the Add commit (epoch drain in Phase 2b).
  // Re-read his current circle state from MDK.
  final bobCircleRefreshed =
      await bob.getCircle(Uint8List.fromList(mlsGroupId));
  if (bobCircleRefreshed == null) {
    throw StateError(
      '[e2e_combined:bob] circle vanished from local MDK after Add commit '
      'drain in Phase 2b. This indicates MDK rolled back the Add commit.',
    );
  }
  _assertCircleHasMembers(
    label: 'bob (after carol joined)',
    circle: bobCircleRefreshed,
    expectedPubkeyHexes: <String>[
      _alicePubkeyHex(),
      bob.pubkeyHex,
      carol.pubkeyHex,
    ],
  );

  // -------------------------------------------------------------------
  // Epoch check: Carol's epoch == Alice's current epoch.
  //
  // Carol joined at the Add epoch (epochBeforeAdd + 1). Alice is at
  // epochBeforeAdd + 1. Both must agree.
  // -------------------------------------------------------------------
  final carolEpoch = await carol.currentEpoch(mlsGroupId);
  final aliceEpochAfterAdd = await _aliceEpochForTest(tester, mlsGroupId);
  expect(
    carolEpoch,
    equals(aliceEpochAfterAdd),
    reason:
        "PHASE 3b: Carol's epoch ($carolEpoch) must equal Alice's "
        'current epoch ($aliceEpochAfterAdd). Carol joined via the Add '
        "Welcome at the post-add epoch; a mismatch means Carol's MDK "
        "accepted a Welcome at the wrong epoch or Alice's epoch was not "
        'correctly read.',
  );
  expect(
    carolEpoch,
    equals(epochBeforeAdd + 1),
    reason:
        "PHASE 3b: Carol's epoch ($carolEpoch) must be exactly "
        '${epochBeforeAdd + 1} (epochBeforeAdd=$epochBeforeAdd + 1). '
        'Carol joined at the Add epoch.',
  );
  debugPrint(
    '[e2e_combined] PHASE 3b epoch check OK — '
    'carol=$carolEpoch alice=$aliceEpochAfterAdd '
    '(both == ${epochBeforeAdd + 1})',
  );

  // -------------------------------------------------------------------
  // NOTE — KP rotation-on-accept is NOT asserted here.
  //
  // KeyPackage rotation after a joiner accepts is production Flutter
  // behavior: `invitation_card.dart` calls `ref.invalidate(
  // keyPackagePublisherProvider)`, which triggers `startJoinerWatch`
  // and republishes a fresh kind 443/30443 for the accepting user.
  // That invalidate→rebuild flow is exercised by the widget/provider
  // unit tests:
  //
  //   haven/test/widgets/circles/invitation_card_test.dart
  //     ("republishes key package after accepting invitation")
  //   haven/test/providers/key_package_provider_test.dart
  //     (keyPackagePublisherProvider publish/failure scenarios)
  //
  // In THIS scenario Carol is a SyntheticUser (FFI peer). Her
  // `acceptInvitationViaRelay` calls the raw FFI directly and never
  // touches `invitation_card.dart` or `keyPackagePublisherProvider`.
  // Alice (the only real Flutter app peer) is the circle creator and
  // never accepts an invitation, so the production republish path is
  // not reachable here. Any poll-for-kind-443/30443 from Carol would
  // be satisfied immediately by her bootstrap KeyPackage published in
  // `setUpAll` — proving nothing about rotation.
  // -------------------------------------------------------------------

  // -------------------------------------------------------------------
  // Behavioral forward-secrecy cross-check.
  //
  // Two assertions:
  //   (a) Carol CAN decrypt a location Alice publishes NOW at the
  //       post-Add epoch (epochBeforeAdd+1 == Carol's join epoch).
  //   (b) Carol CANNOT decrypt [preAddLocationEvent] — Bob's location
  //       published at the init epoch (before the Add commit). This is
  //       the MLS forward-secrecy / epoch-boundary guarantee for added
  //       members: Carol joined via the Add Welcome which delivered only
  //       epoch secrets from epochBeforeAdd+1 onward; the init-epoch
  //       exporter secret that encrypted Bob's pre-add location was
  //       never part of Carol's Welcome, so MDK has no key to decrypt
  //       with and returns null.
  //
  // Why Bob, not Alice, for the pre-add event: Alice's group advanced
  // to epochBeforeAdd+1 atomically when she committed the Add, so there
  // is no window to publish an Alice location at the OLD epoch within
  // this flow. Bob, as an existing member who accepted before the Add,
  // published at the init epoch (2-member phase). That event is
  // [preAddLocationEvent], captured and relay-confirmed before
  // _aliceAddsCarolViaUi ran.
  // -------------------------------------------------------------------

  // (a) Alice publishes a post-add location and Carol decrypts it.
  //
  // Capture a `since` timestamp BEFORE the publish so the positive
  // drain only fetches kind-445 events from this moment onward.
  // Without `since`, drainPendingCommits would collect ALL kind-445
  // for the group — including Bob's pre-add location — which has
  // two problems:
  //   (i)  The positive proof is loose: it could match the stale
  //        pre-add event instead of the fresh post-add one.
  //   (ii) Carol's MDK would attempt (and fail) the pre-add event
  //        here first, producing a `PreviouslyFailed` dedup entry.
  //        The subsequent negative forward-secrecy check (b) then
  //        passes partly due to MDK dedup, not the epoch-boundary
  //        denial we want to prove.
  // With `since` anchored here, the positive drain only surfaces
  // the post-add event, leaving the pre-add event untouched so
  // assertion (b) is Carol's genuine FIRST decrypt attempt of that
  // ciphertext — a true protocol-level test.
  final postAddSinceSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(locationPublisherProvider);
  final publishedCount = await container.read(locationPublisherProvider.future);
  expect(
    publishedCount,
    greaterThanOrEqualTo(1),
    reason:
        "PHASE 3b: Alice's locationPublisherProvider must publish to at "
        'least one accepted circle after the add. Got 0.',
  );

  // Carol drains and must decrypt Alice's location. We poll with a bounded
  // budget because the relay round-trip adds latency. The `since` parameter
  // scopes the drain to post-add events only (see rationale above).
  final aliceHex = _alicePubkeyHex().toLowerCase();
  await _pollUntil<bool>(
    describe:
        "Carol decrypting Alice's post-add location (epoch cross-check: "
        'Carol joined at the add epoch and must decrypt post-add traffic)',
    probe: () async {
      final summary = await carol.drainPendingCommits(
        relay: ctx.relay,
        circle: carolCircle,
        since: DateTime.fromMillisecondsSinceEpoch(postAddSinceSecs * 1000),
      );
      return summary.decryptedLocationSenders.contains(aliceHex);
    },
    satisfied: (decrypted) => decrypted,
  );
  debugPrint(
    '[e2e_combined] PHASE 3b forward-secrecy cross-check (positive) OK — '
    "Carol CAN decrypt Alice's post-add location (joined at add epoch).",
  );

  // -------------------------------------------------------------------
  // (b) Forward-secrecy NEGATIVE assertion — Carol CANNOT decrypt the
  //     pre-add location event.
  //
  // [preAddLocationEvent] was encrypted by Bob at the init epoch
  // (epochBeforeAdd) — before Carol's Add Welcome was issued. Carol's
  // Welcome delivered only epoch secrets from epochBeforeAdd+1 onward
  // (RFC 9420 §8.1: the joiner's exporter secret is derived from the
  // epoch created by the Add commit, not from any prior epoch). MDK
  // therefore has no key material to decrypt a ciphertext sealed under
  // the init-epoch exporter secret.
  //
  // This is the MLS forward-secrecy / epoch-boundary guarantee for
  // added members — the inverse of the post-add positive case above.
  // We use applyArrivalOrdered with the single captured event, the
  // same drain/apply path the production client uses, so this assertion
  // catches a regression in MDK's epoch-boundary enforcement rather
  // than merely a missing API call.
  //
  // Robustness: both a null return (unknown event) and a thrown FFI
  // error (Unprocessable / PreviouslyFailed) legitimately mean "cannot
  // decrypt"; _applyEventsInOrder absorbs each into "not decrypted"
  // without adding the sender to decryptedLocationSenders. The
  // assertion fires only if Carol actually decrypts Bob's pre-add
  // ciphertext, which would be a cryptographic protocol violation.
  // -------------------------------------------------------------------
  final carolPreAddSummary = await carol.applyArrivalOrdered(
    <TestRelayEvent>[preAddLocationEvent],
    relay: ctx.relay,
  );
  final bobHex = bob.pubkeyHex.toLowerCase();
  final carolDecryptedPreAdd =
      carolPreAddSummary.decryptedLocationSenders.contains(bobHex) ||
      carolPreAddSummary.decryptedLocations.containsKey(bobHex);
  expect(
    carolDecryptedPreAdd,
    isFalse,
    reason:
        'FORWARD SECRECY VIOLATION (Add / epoch boundary): Carol decrypted '
        "Bob's pre-add location "
        '(id=${_redactPk(preAddLocationEvent.id)}). '
        'Carol joined at epoch ${epochBeforeAdd + 1} via the Add Welcome; '
        'the pre-add event was encrypted at epoch $epochBeforeAdd whose '
        "exporter secret was NEVER part of Carol's Welcome (RFC 9420 §8.1). "
        'A non-null decrypt here means MDK delivered the pre-add epoch '
        'secret to Carol through the Add Welcome — a cryptographic '
        'protocol violation. '
        'carolDecryptedSenders='
        '${carolPreAddSummary.decryptedLocationSenders}',
  );
  debugPrint(
    '[e2e_combined] PHASE 3b forward-secrecy cross-check (negative) OK — '
    "Carol CANNOT decrypt Bob's pre-add location "
    '(MLS epoch-boundary / forward-secrecy guarantee for added members).',
  );

  debugPrint('[e2e_combined] PHASE 3b complete.');
}

// =============================================================================
// PHASE 4 helpers — three-way location sharing
// =============================================================================

Future<void> _publishAndObserveThreeWayLocations({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required SyntheticUser bob,
  required SyntheticUser carol,
  required CircleWithMembersFfi bobCircle,
  required CircleWithMembersFfi carolCircle,
}) async {
  // -----------------------------------------------------------------
  // Step 1 — Alice publishes her location via the production
  // `locationPublisherProvider`. Invalidating + reading the provider
  // forces a publish even if the periodic timer hasn't fired yet.
  // -----------------------------------------------------------------
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(locationPublisherProvider);
  final published = await container.read(
    locationPublisherProvider.future,
  );
  expect(
    published,
    greaterThanOrEqualTo(1),
    reason:
        'locationPublisherProvider must have published to at least one '
        'accepted circle; got 0 — either encryptLocation no-op-ed or '
        'no accepted circle is in scope.',
  );

  // -----------------------------------------------------------------
  // Step 2 — Bob and Carol publish their locations via FFI. Each
  // call encrypts a kind-445 via `encryptLocation` and publishes
  // it to the same hermetic relay Alice publishes to.
  // -----------------------------------------------------------------
  await bob.publishLocation(
    circle: bobCircle,
    latitude: bobFakeLatitude,
    longitude: bobFakeLongitude,
    relay: ctx.relay,
  );
  await carol.publishLocation(
    circle: carolCircle,
    latitude: carolFakeLatitude,
    longitude: carolFakeLongitude,
    relay: ctx.relay,
  );

  // -----------------------------------------------------------------
  // Step 3 — Alice observes Bob and Carol's locations in her
  // `memberLocationsProvider`. The retry loop absorbs the MLS
  // epoch race (Alice's MDK may need to apply Bob's and Carol's
  // ratchet generations).
  //
  // We deliberately do NOT assert on `find.byKey(memberMarker(pk))`:
  // `flutter_map`'s MarkerLayer culls off-viewport markers out of
  // the widget tree, and the synthetic peers' sentinel coordinates
  // sit tens of thousands of pixels from Alice's map centre. The
  // provider-data assertion verifies the entire integration we
  // care about (encrypt → publish → relay → fetch → decrypt →
  // persist → provider). Marker rendering is covered by the
  // `MapPage` widget test.
  //
  // Epoch-aware convergence: rather than a blind retry budget, we
  // gate on the actual provider state (memberLocationsProvider must
  // surface both Bob and Carol as senders). This is more robust than
  // a wall-clock wait because it detects the convergence condition
  // directly on the production data plane, matching the real MLS
  // epoch the group is at after Phase 2b's Add commit.
  // -----------------------------------------------------------------
  final expectedPeerSet = <String>{
    bob.pubkeyHex.toLowerCase(),
    carol.pubkeyHex.toLowerCase(),
  };
  // Keep the last complete location list so we can assert coordinates
  // after the convergence loop rather than inside it (the assertion
  // only runs once all peers are present).
  var aliceLastLocs = <MemberLocation>[];
  // FE-1: replaced the fixed `Future.delayed(5s)` wall-clock wait with a
  // bounded `_pollUntil` on the actual convergence condition — membership
  // in `memberLocationsProvider`. The probe invalidates and re-reads all
  // three relevant providers on each attempt (same as the old for-loop),
  // drives three short tester pumps to flush rebuild listeners, and returns
  // the missing-peer set. `_pollUntil` gates on `missing.isEmpty` and uses
  // `_convergencePollInterval` (3 s) between attempts with a
  // `_peerConvergenceBudget` (60 s) outer deadline. Removing the sleep
  // means the test never waits longer than necessary and the deadline is
  // enforced by the actual condition, not by an iteration count.
  await _pollUntil<Set<String>>(
    describe:
        'alice: memberLocationsProvider convergence — expected '
        '${expectedPeerSet.length} peers '
        '(${expectedPeerSet.map(_redactPk).join(", ")})',
    probe: () async {
      container
        ..invalidate(locationPublisherProvider)
        ..invalidate(evolutionPollerProvider)
        ..invalidate(memberLocationsProvider);
      await container.read(locationPublisherProvider.future);
      await container.read(evolutionPollerProvider.future);
      final locs = await container.read(memberLocationsProvider.future);

      // Three short pumps cover any rebuild listeners scheduled by
      // the provider reads above without depending on the global
      // frame queue draining (MapShell's periodic timers keep it
      // perpetually non-empty under IntegrationTestWidgetsFlutterBinding).
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      aliceLastLocs = locs;
      final present = locs.map((l) => l.pubkey.toLowerCase()).toSet();
      final missing = expectedPeerSet.difference(present);
      if (missing.isNotEmpty) {
        debugPrint(
          '[e2e_combined:alice] PHASE 4 poll — '
          'memberLocationsProvider missing ${missing.length} peers',
        );
      }
      return missing;
    },
    satisfied: (missing) => missing.isEmpty,
  );
  // `_pollUntil` throws a `StateError` on timeout, so reaching here
  // guarantees the satisfied predicate held. The explicit `expect` below
  // is retained as a loud, test-framework-visible assertion that names the
  // failure mode — it cannot be vacuous because `_pollUntil` already
  // ensures the set is empty.
  expect(
    expectedPeerSet.difference(
      aliceLastLocs.map((l) => l.pubkey.toLowerCase()).toSet(),
    ),
    isEmpty,
    reason:
        "alice: memberLocationsProvider did not surface every peer's "
        'location within the retry budget. Either decryptLocation '
        "returned null, the MLS epoch race didn't converge, or the "
        'shared `_persistDecryptedLocation` helper in '
        'location_sharing_service.dart has regressed (fetch vs poller '
        'race).',
  );

  // Assert that Alice's provider surfaced the correct coordinates for
  // each peer — not merely that the entries are present. This catches
  // a "decrypt succeeds but returns corrupt coordinates" regression
  // that the sender-presence check above cannot detect.
  _assertMemberLocationCoordinates(
    label: 'alice → bob (via memberLocationsProvider)',
    locs: aliceLastLocs,
    senderPubkeyHex: bob.pubkeyHex,
    expectedLatitude: bobFakeLatitude,
    expectedLongitude: bobFakeLongitude,
  );
  _assertMemberLocationCoordinates(
    label: 'alice → carol (via memberLocationsProvider)',
    locs: aliceLastLocs,
    senderPubkeyHex: carol.pubkeyHex,
    expectedLatitude: carolFakeLatitude,
    expectedLongitude: carolFakeLongitude,
  );

  // -----------------------------------------------------------------
  // Step 4 — Bob and Carol observe each other AND Alice via FFI.
  // The drain helper fetches every kind-445 on the relay (filtered
  // by `#h=nostr_group_id`) and decrypts each through their MDK.
  // After draining, the peer's local cache holds every successfully-
  // decrypted location.
  // -----------------------------------------------------------------
  final bobDecryptedCoords = await _drainUntilLocationsVisible(
    peer: bob,
    relay: ctx.relay,
    circle: bobCircle,
    expectedSenders: <String>{
      _alicePubkeyHex().toLowerCase(),
      carol.pubkeyHex.toLowerCase(),
    },
  );
  final carolDecryptedCoords = await _drainUntilLocationsVisible(
    peer: carol,
    relay: ctx.relay,
    circle: carolCircle,
    expectedSenders: <String>{
      _alicePubkeyHex().toLowerCase(),
      bob.pubkeyHex.toLowerCase(),
    },
  );

  // Assert coordinates on the synthetic-peer side. A decrypt that
  // returns the wrong lat/lon (e.g. due to a serialisation bug in the
  // kind-9 content encoding) would pass the presence check above but
  // fail here, providing an unambiguous regression signal.
  _assertDecryptedCoords(
    label: 'bob decrypted alice',
    coords: bobDecryptedCoords,
    senderPubkeyHex: _alicePubkeyHex(),
    expectedLatitude: aliceFakeLatitude,
    expectedLongitude: aliceFakeLongitude,
  );
  _assertDecryptedCoords(
    label: 'bob decrypted carol',
    coords: bobDecryptedCoords,
    senderPubkeyHex: carol.pubkeyHex,
    expectedLatitude: carolFakeLatitude,
    expectedLongitude: carolFakeLongitude,
  );
  _assertDecryptedCoords(
    label: 'carol decrypted alice',
    coords: carolDecryptedCoords,
    senderPubkeyHex: _alicePubkeyHex(),
    expectedLatitude: aliceFakeLatitude,
    expectedLongitude: aliceFakeLongitude,
  );
  _assertDecryptedCoords(
    label: 'carol decrypted bob',
    coords: carolDecryptedCoords,
    senderPubkeyHex: bob.pubkeyHex,
    expectedLatitude: bobFakeLatitude,
    expectedLongitude: bobFakeLongitude,
  );

  debugPrint('[e2e_combined] PHASE 4 complete (3-way locations + coords).');
}

/// Repeatedly awaits [probe] until [satisfied] holds or [budget]
/// elapses, sleeping [interval] between attempts; returns the last
/// probe result on success and throws a `StateError` tagged with
/// [describe] (and the final result) on timeout.
///
/// Centralizes the convergence-poll skeleton the relay/MLS phases
/// share — relay + MLS convergence is genuinely async with no single
/// gating wire event, so the phases poll. Keeping the cadence and the
/// actionable timeout message here avoids the copy-pasted
/// `while (deadline) { … delay … }` blocks each phase used to carry.
Future<T> _pollUntil<T>({
  required Future<T> Function() probe,
  required bool Function(T result) satisfied,
  required String describe,
  Duration budget = _peerConvergenceBudget,
  Duration interval = _convergencePollInterval,
}) async {
  final deadline = DateTime.now().add(budget);
  Object? lastResult;
  while (DateTime.now().isBefore(deadline)) {
    final result = await probe();
    lastResult = result;
    if (satisfied(result)) return result;
    await Future<void>.delayed(interval);
  }
  throw StateError(
    '[e2e_combined] convergence timed out after ${budget.inSeconds}s: '
    '$describe (last result: $lastResult)',
  );
}

/// Drains kind-445 events from [relay] for [peer]'s circle until
/// every pubkey in [expectedSenders] has been observed as the sender
/// of at least one successfully-decrypted location event.
///
/// Uses the **identity set** returned by `drainPendingCommits`, not
/// the count, because Rust's dedup means successive drains return
/// the same events but only decrypt new ones — counting would
/// inflate vacuously while missing real coverage.
///
/// Accumulates senders AND their coordinates across drain iterations
/// so we converge as new peers' locations land on subsequent fetches,
/// even when an earlier drain only saw a subset. The returned map
/// contains the first-seen coordinates per sender (lowercase hex key)
/// and is the basis for post-drain coordinate assertions.
Future<Map<String, DecryptedCoords>> _drainUntilLocationsVisible({
  required SyntheticUser peer,
  required TestRelay relay,
  required CircleWithMembersFfi circle,
  required Set<String> expectedSenders,
}) async {
  final accumulatedSenders = <String>{};
  final accumulatedCoords = <String, DecryptedCoords>{};
  await _pollUntil<Set<String>>(
    describe:
        '${peer.label} location convergence — expected '
        '${expectedSenders.length} distinct senders',
    probe: () async {
      final summary = await peer.drainPendingCommits(
        relay: relay,
        circle: circle,
      );
      accumulatedSenders.addAll(summary.decryptedLocationSenders);
      // Merge coordinates; putIfAbsent keeps the first successful
      // decrypt (subsequent rounds return null from Rust dedup so
      // the summary map for those entries is simply empty).
      summary.decryptedLocations.forEach((pk, coords) {
        accumulatedCoords.putIfAbsent(pk, () => coords);
      });
      return expectedSenders.difference(accumulatedSenders);
    },
    satisfied: (missing) => missing.isEmpty,
  );
  debugPrint(
    '[e2e_combined:${peer.label}] location convergence ok '
    '(${accumulatedSenders.length}/${expectedSenders.length} '
    'distinct senders decrypted)',
  );
  return accumulatedCoords;
}

// =============================================================================
// PHASE 5 helpers — Alice leaves through the UI; Bob and Carol observe
// =============================================================================

Future<void> _aliceLeavesViaUi({
  required WidgetTester tester,
  required String nostrGroupIdHex,
}) async {
  // Select by stable WidgetKey, not the translatable "Circle details"
  // tooltip — the tooltip stays for accessibility, but the selector
  // no longer breaks on a copy/i18n change.
  final detailsButton = find.byKey(WidgetKeys.circleDetailsButton);
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        "After PHASE 2/4, Alice's selected-circle header with its "
        'circle-details info button must be visible in the bottom sheet.',
  );
  await tester.tap(detailsButton);
  // Modal opens on top of MapShell — wait for the Leave Circle CTA
  // to be findable rather than pumpAndSettle (MapShell's timers
  // keep the frame queue non-empty even while the modal is up).
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.leaveCircleCta),
    description: 'leaveCircleCta after tapping circle-details info button',
  );

  final leaveCta = find.byKey(WidgetKeys.leaveCircleCta);
  await tester.ensureVisible(leaveCta);
  // Two short pumps cover any post-ensureVisible layout pass
  // (modal scroll position, sliver header collapse) without
  // depending on a settle that would hang.
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(leaveCta);
  // Wait for the confirmation dialog's keyed "Leave" button. Keying
  // it disambiguates from the dialog title "Leave Circle" without a
  // brittle widgetWithText(TextButton, 'Leave') text match.
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.leaveCircleConfirm),
    description: 'Leave confirmation dialog after tapping Leave Circle',
  );

  await tester.tap(find.byKey(WidgetKeys.leaveCircleConfirm));

  // FFI: planLeave (AdminHandoff) → proposeAdminHandoff → publish →
  // finalize → proposeSelfDemote → publish → finalize → proposeLeave →
  // publish → completeLeave. Three relay round-trips.
  //
  // pumpUntilGone, not pumpAndSettle: the dialog pops immediately
  // when the tap is processed, then the async FFI chain begins.
  // pumpAndSettle can see a momentarily-empty frame queue BETWEEN
  // the dialog close and the next FFI await, settle prematurely,
  // and let the next assertion fire while the chain is still in
  // flight. Waiting on the actual observable — the circle selector's
  // active-selection widget leaving the tree — gates the next
  // assertion on the work being done. The key is scoped to
  // [nostrGroupIdHex] so the finder cannot false-match another
  // circle or a SnackBar carrying the circle name.
  await pumpUntilGone(
    tester,
    find.byKey(WidgetKeys.circleSelectorActive(nostrGroupIdHex)),
    timeout: const Duration(seconds: 60),
    description:
        'circle selector active-tile (id: ${nostrGroupIdHex.substring(0, 8)}…) '
        'disappearing after Alice taps Leave',
  );

  expect(find.byType(MapShell), findsOneWidget);
  expect(
    find.byKey(WidgetKeys.circleSelectorActive(nostrGroupIdHex)),
    findsNothing,
    reason:
        'After AdminHandoff completes, the "$_circleName" circle '
        '(nostrGroupId: ${nostrGroupIdHex.substring(0, 8)}…) must no '
        "longer appear as the active selection in Alice's circle selector.",
  );
  debugPrint('[e2e_combined:alice] PHASE 5 (Leave via UI) complete.');
}

/// A live, arrival-ordered capture of one circle's kind-445 stream.
///
/// Opened BEFORE the publisher acts so events arrive in publish
/// order (= MLS-epoch order for a single publisher emitting commits
/// sequentially). [snapshot] returns the buffer in arrival order;
/// callers re-pass it across convergence rounds (re-applying
/// already-seen events is a no-op in MDK).
///
/// This sidesteps the fundamental limitation of fetching commits
/// after the fact and sorting by `created_at` (1-second resolution
/// cannot order same-second commits; one out-of-order submission
/// permanently poisons MDK's sticky `Unprocessable` cache — see
/// docs/E2E_TROUBLESHOOTING.md).
class _ArrivalOrderedInbox {
  _ArrivalOrderedInbox({
    required TestRelay relay,
    required Uint8List nostrGroupId,
  }) {
    final hex = _hexLower(nostrGroupId);
    // `since` = construction time (constructed just before Alice
    // leaves) so the buffer contains ONLY the handoff commits, the
    // two competing commits, and the convergence probe — never the
    // Phase-4 location events. This keeps the buffer small and makes
    // the cross-branch probe unambiguous: the only location event a
    // peer can decrypt here is the fresh post-handoff probe.
    final sinceSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _sub = relay
        .events(<String, dynamic>{
          'kinds': const <int>[445],
          '#h': <String>[hex],
          'since': sinceSecs,
        })
        .listen(_buffer.add);
  }

  final List<TestRelayEvent> _buffer = <TestRelayEvent>[];
  late final StreamSubscription<TestRelayEvent> _sub;

  /// The events captured so far, in arrival order.
  List<TestRelayEvent> snapshot() => List<TestRelayEvent>.of(_buffer);

  Future<void> dispose() => _sub.cancel();
}

/// Drives both peers through the admin-handoff WITHOUT forking, then
/// returns each peer's up-to-date circle once they are provably on the
/// SAME MLS branch.
///
/// ## The problem: a multi-committer fork
///
/// `LeavePlan::AdminHandoff` ends with a SelfRemove PROPOSAL. Per
/// RFC 9420 §12.1.2 (and matching whitenoise), EVERY remaining member
/// auto-commits it — so if both Bob and Carol commit it, each mints a
/// competing epoch-3→4 commit and the group FORKS. Their member sets
/// coincide (both removed Alice), so a member-set check can't tell a
/// reconciled group from a forked one. Critically, this MDK rev does
/// NOT reliably reconcile such a fork by re-processing the competing
/// commits: the first wrong-epoch attempt poisons MDK's sticky
/// `Unprocessable` cache before `is_better_candidate` can roll back
/// (confirmed by CI — 20 re-drain rounds never converged).
///
/// ## The fix: elect ONE committer, the loser adopts it
///
/// This is the exact shape the in-repo Rust test
/// `concurrent_admin_remove_member_converges_after_clear_pending`
/// (`haven-core/src/circle/manager.rs`) proves converges:
///   1. Elect the winner deterministically as the `select_successor`
///      result — the lex-smallest of `{bob, carol}` (which is also the
///      new admin after the handoff). No MLS-internal state read needed.
///   2. The WINNER applies Alice's three handoff events normally
///      (finalizing its SelfRemove auto-commit) → it advances to epoch
///      4 and publishes its commit `C_winner`.
///   3. The LOSER applies Alice's handoff but withholds its own
///      auto-commit (`finalizeAutoCommit: false`, leaving it pending),
///      then `clearPendingCommit`s that pending commit and applies
///      `C_winner` instead → a clean forward apply onto the winner's
///      epoch-4 branch, with NO competing commit ever published and so
///      NO cache-poisoning fork.
///
/// Because only one finalized SelfRemove commit ever exists, there is
/// nothing to reconcile. Convergence is then VERIFIED behaviorally (no
/// MLS-internal FFI): the winner publishes a fresh location and the
/// loser must DECRYPT it — only possible on a shared epoch-4 branch.
/// Pre-handoff locations are unprocessable at the new epoch, so a
/// positive decrypt is unambiguous. Entirely inside the integration
/// test — zero production surface, zero secret exposure.
Future<({CircleWithMembersFfi bob, CircleWithMembersFfi carol})>
_reconcileHandoff({
  required SyntheticUser bob,
  required SyntheticUser carol,
  required _ArrivalOrderedInbox inbox,
  required TestRelay relay,
  required CircleWithMembersFfi bobCircle,
  required CircleWithMembersFfi carolCircle,
}) async {
  final aliceHex = _alicePubkeyHex().toLowerCase();
  final mlsGroupId = bobCircle.circle.mlsGroupId;

  // Winner = lex-smallest pubkey, mirroring `select_successor` (the new
  // admin after the handoff). The loser adopts the winner's commit.
  final bobHex = bob.pubkeyHex.toLowerCase();
  final carolHex = carol.pubkeyHex.toLowerCase();
  final bobWins = bobHex.compareTo(carolHex) < 0;
  final winner = bobWins ? bob : carol;
  final loser = bobWins ? carol : bob;
  debugPrint(
    '[e2e_combined] handoff: winner=${winner.label} '
    '(lex-smallest), loser=${loser.label}',
  );

  // 1. Capture Alice's three handoff events (AdminHandoff → SelfDemote
  //    → SelfRemove) in arrival order. The `since`-filtered inbox sees
  //    only post-leave events, and Alice publishes them sequentially
  //    (awaiting each relay OK), so the first three are exactly these
  //    in MLS-epoch order.
  await _pollUntil<int>(
    describe: "Alice's three handoff commits landing on the relay",
    probe: () async => inbox.snapshot().length,
    satisfied: (n) => n >= 3,
  );
  final aliceCommits = inbox.snapshot().take(3).toList();

  // 2. Winner applies the handoff normally → epoch 4, publishes
  //    C_winner.
  await winner.applyArrivalOrdered(aliceCommits, relay: relay);

  // 3. Wait for C_winner to arrive in the inbox (the winner's published
  //    commit is the first event after Alice's three).
  await _pollUntil<int>(
    describe: "the winner's SelfRemove commit landing on the relay",
    probe: () async => inbox.snapshot().length,
    satisfied: (n) => n >= 4,
  );
  final winnerCommits = inbox.snapshot().skip(3).toList();

  // 4. Loser applies Alice's handoff WITHOUT finalizing its own
  //    SelfRemove auto-commit (left pending), clears that pending
  //    commit, then forward-applies C_winner — landing on the winner's
  //    branch with no competing commit ever published.
  await loser.applyArrivalOrdered(
    aliceCommits,
    relay: relay,
    finalizeAutoCommit: false,
  );
  await loser.clearPendingCommit(mlsGroupId);
  await loser.applyArrivalOrdered(winnerCommits, relay: relay);

  // 5. Verify both are on the SAME branch: the winner publishes a fresh
  //    location and the loser must decrypt it. A bounded poll absorbs
  //    relay round-trip latency; failure here means the election did
  //    not converge the two peers.
  final winnerHex = winner.pubkeyHex.toLowerCase();
  await _pollUntil<bool>(
    describe:
        "${loser.label} decrypting ${winner.label}'s post-handoff "
        'location (proving a shared MLS branch)',
    probe: () async {
      final winnerCircle = await winner.getCircle(mlsGroupId);
      if (winnerCircle == null) {
        throw StateError(
          '[e2e_combined] winner ${winner.label} lost its circle during '
          'the convergence probe.',
        );
      }
      await winner.publishLocation(
        circle: winnerCircle,
        latitude: bobFakeLatitude,
        longitude: bobFakeLongitude,
        relay: relay,
      );
      final summary = await loser.drainPendingCommits(
        relay: relay,
        circle: bobCircle,
      );
      return summary.decryptedLocationSenders.contains(winnerHex);
    },
    satisfied: (decrypted) => decrypted,
    budget: const Duration(seconds: 30),
  );

  final bobFinal = await bob.getCircle(mlsGroupId);
  final carolFinal = await carol.getCircle(mlsGroupId);
  if (bobFinal == null || carolFinal == null) {
    throw StateError(
      '[e2e_combined] a peer circle vanished during the handoff '
      'single-committer election — a peer was inadvertently removed.',
    );
  }
  if (!_residualMembersOk(bobFinal, aliceHex) ||
      !_residualMembersOk(carolFinal, aliceHex)) {
    throw StateError(
      '[e2e_combined] handoff election left an unexpected residual: '
      'bobMembers=${bobFinal.members.length} '
      'carolMembers=${carolFinal.members.length} (expected Alice gone, '
      '2 members, 1 admin on both).',
    );
  }
  debugPrint(
    '[e2e_combined] handoff converged via single-committer election — '
    "${loser.label} adopted ${winner.label}'s commit (probe decrypted).",
  );
  return (bob: bobFinal, carol: carolFinal);
}

/// True when [circle] shows the expected post-handoff residual: Alice
/// gone, exactly two members, exactly one admin.
bool _residualMembersOk(CircleWithMembersFfi circle, String aliceHex) {
  final hasAlice = circle.members.any(
    (m) => m.pubkey.toLowerCase() == aliceHex,
  );
  final adminCount = circle.members.where((m) => m.isAdmin).length;
  return !hasAlice && circle.members.length == 2 && adminCount == 1;
}

void _assertResidualGroupAfterHandoff({
  required String label,
  required CircleWithMembersFfi circle,
  required String selfPubkeyHex,
  required String peerPubkeyHex,
}) {
  // Exactly two members remain.
  expect(
    circle.members.length,
    equals(2),
    reason:
        '$label: residual member count after Alice left is '
        '${circle.members.length}, expected exactly 2. Either Alice '
        "remained, the wrong member was removed, or MDK's committed "
        "group state diverged from Haven's expectation.",
  );
  // Exactly one admin (the lex-smallest non-self, per select_successor).
  final admins = circle.members.where((m) => m.isAdmin).toList();
  expect(
    admins.length,
    equals(1),
    reason:
        '$label: residual group has ${admins.length} admins, expected '
        'exactly 1. A 0-admin state means proposeAdminHandoff was '
        'skipped; a 2-admin state means AdminHandoff promoted the '
        'successor but the subsequent SelfDemote did not apply.',
  );
  // The two members are exactly {self, peer}.
  final memberSet = circle.members.map((m) => m.pubkey.toLowerCase()).toSet();
  expect(
    memberSet,
    equals(<String>{
      selfPubkeyHex.toLowerCase(),
      peerPubkeyHex.toLowerCase(),
    }),
    reason:
        '$label: residual member set does not match {self, peer}. '
        'Either an extra member was added or one of self/peer was '
        'removed in error.',
  );
}

/// Asserts core Marmot/Haven wire-privacy invariants against what the
/// hermetic relay actually observed for [circle]'s kind-445 stream.
///
/// These are RELAY-LAYER checks (no widget finders), so they verify
/// real protocol/privacy guarantees without coupling to any UI:
///
/// - **Ephemeral key per group message** (MIP-03 rule #2): every
///   kind-445 must be signed by a distinct, throwaway pubkey — never
///   reused across messages, and never a member's long-term identity
///   pubkey. Reuse would let a relay link a member's messages.
/// - **No real MLS group id on the wire** (Security Rule #4): only the
///   `nostr_group_id` (the `h` tag) may appear; the real MLS group id
///   must never leak into any tag.
/// - **No forbidden event kinds on the wire**: no kind-0 profiles
///   (pubkey-only identity), no kind-3 contact lists (no social-graph leak),
///   and no kind-10002 NIP-65 relay lists (Haven uses 10050/10051 only); plus
///   **no bare kind-444 Welcomes** (they stay gift-wrapped inside kind-1059,
///   and are unsigned per Security Rule #3).
Future<void> _assertWirePrivacyInvariants({
  required TestRelay relay,
  required CircleWithMembersFfi circle,
  required Set<String> identityPubkeyHexes,
}) async {
  final nostrGroupIdHex = _hexLower(circle.circle.nostrGroupId);
  final mlsGroupIdHex = _hexLower(circle.circle.mlsGroupId);

  // Guard: the group-id leak scan (below) is only meaningful when the two
  // IDs differ. Equal values would let the tag scan pass vacuously even if
  // the real MLS group id leaked — both checks would be looking for the same
  // hex string, which would be expected to appear in the h-tag. An explicit
  // precondition here causes the test to fail immediately if the Rust layer
  // returns the same bytes for both IDs (id-aliasing bug).
  expect(
    mlsGroupIdHex,
    isNot(equals(nostrGroupIdHex)),
    reason:
        'group-id leak scan is only meaningful if the two ids differ; '
        'equal values would make the scan vacuous and mask a potential '
        'id-aliasing bug in the Rust layer.',
  );

  final events = await relay.collectN(
    count: 200,
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      '#h': <String>[nostrGroupIdHex],
      'limit': 200,
    },
    timeout: const Duration(seconds: 5),
  );
  expect(
    events,
    isNotEmpty,
    reason: 'expected kind-445 group messages on the relay after Phase 4',
  );

  // Ephemeral-key-per-message: author pubkeys must be unique and
  // never a long-term identity key.
  final authorPubkeys = events.map((e) => e.pubkey.toLowerCase()).toList();
  final distinctAuthors = authorPubkeys.toSet();
  expect(
    distinctAuthors.length,
    equals(authorPubkeys.length),
    reason:
        'kind-445 ephemeral pubkeys must be unique per message '
        '(MIP-03 rule 2) — found '
        '${authorPubkeys.length - distinctAuthors.length} reused.',
  );
  for (final pk in distinctAuthors) {
    expect(
      identityPubkeyHexes.contains(pk),
      isFalse,
      reason:
          'a kind-445 was signed by a long-term identity pubkey '
          '(${_redactPk(pk)}) instead of a fresh ephemeral key '
          '(MIP-03 rule 2).',
    );
  }

  // Group-ID privacy: the real MLS group id must appear in NO tag; the
  // `h` tag must carry the nostr_group_id.
  for (final e in events) {
    final hTag = e.tag('h');
    final hMatches =
        hTag != null &&
        hTag.length >= 2 &&
        hTag[1].toLowerCase() == nostrGroupIdHex;
    expect(
      hMatches,
      isTrue,
      reason:
          'kind-445 ${_redactPk(e.id)} must carry the nostr_group_id in '
          'its h tag, not the real MLS group id (Security Rule 4).',
    );
    for (final tag in e.tags) {
      for (final value in tag) {
        expect(
          value.toLowerCase().contains(mlsGroupIdHex),
          isFalse,
          reason:
              'the real MLS group id leaked into a kind-445 tag on event '
              '${_redactPk(e.id)} (Security Rule 4).',
        );
      }
    }

    // Recipient privacy: a kind-445 group message must route ONLY by the
    // `h` (group) tag — never by per-recipient `p` tags. A `p` tag would
    // let the relay enumerate who is in the circle, defeating the
    // group-messaging privacy model (MIP-03). The ephemeral sender key
    // already hides the author; a `p` tag would re-attach recipients.
    expect(
      e.tag('p'),
      isNull,
      reason:
          'kind-445 ${_redactPk(e.id)} carries a `p` (recipient) tag — '
          'that deanonymizes circle membership at the relay. Group '
          'messages must route by the `h` tag alone (MIP-03).',
    );
  }
  debugPrint(
    '[e2e_combined] wire-privacy invariants OK '
    '(${events.length} kind-445, ${distinctAuthors.length} distinct '
    'ephemeral keys, no MLS group id on the wire, no recipient p-tags)',
  );

  // These event kinds must NEVER reach a relay. Haven's privacy model publishes
  // only pubkey-scoped group (445), gift-wrapped (1059), and relay-list
  // (10050/10051) events. An explicit forbid-list {0, 3, 10002} is used rather
  // than a closed allow-set so a future legitimate kind doesn't make this
  // assertion spuriously fail on a cosmetic protocol addition.
  //   - kind 0      profile: would correlate a username/avatar with a pubkey.
  //   - kind 3      contact/following list: would expose the user's social graph.
  //   - kind 10002  NIP-65 relay list: Haven publishes 10050/10051, never 10002.
  // One combined REQ keeps the (empty-result) wait to a single timeout window
  // and reports the offending kind(s) on failure.
  final forbidden = await relay.collectN(
    count: 50,
    filter: <String, dynamic>{
      'kinds': const <int>[0, 3, 10002],
      'limit': 50,
    },
    timeout: const Duration(seconds: 3),
  );
  final forbiddenKindsSeen = forbidden.map((e) => e.kind).toSet();
  expect(
    forbidden,
    isEmpty,
    reason:
        'forbidden event kind(s) $forbiddenKindsSeen reached the relay — '
        'Haven must never publish kind-0 profiles, kind-3 contact lists, or '
        'kind-10002 NIP-65 relay lists.',
  );

  // A kind-444 Welcome must NEVER appear bare on the relay: it is always
  // gift-wrapped inside a kind-1059 (NIP-59) and is itself UNSIGNED
  // (Security Rule #3 / MIP-04). A bare 444 — signed or not — is a regression.
  final welcomes = await relay.collectN(
    count: 50,
    filter: <String, dynamic>{
      'kinds': const <int>[444],
      'limit': 50,
    },
    timeout: const Duration(seconds: 3),
  );
  // Check signatures FIRST so a SIGNED bare 444 fails with a precise reason
  // (kind-444 is unsigned per Security Rule #3 / MIP-04). The final invariant
  // — no bare 444 on the relay at all — is the isEmpty assertion below;
  // ordering the signature scan before it keeps BOTH checks live (an isEmpty
  // that threw first would make this loop dead code).
  for (final w in welcomes) {
    final dynamic sig = w.raw['sig'];
    final hasSignature = sig is String && sig.isNotEmpty;
    expect(
      hasSignature,
      isFalse,
      reason:
          'an observed kind-444 carries a signature — Welcomes must remain '
          'unsigned (Security Rule #3).',
    );
  }
  expect(
    welcomes,
    isEmpty,
    reason:
        'a bare kind-444 Welcome reached the relay — Welcomes must stay '
        'gift-wrapped inside kind-1059 (NIP-59), never published directly.',
  );
  debugPrint(
    '[e2e_combined] wire-privacy invariants OK '
    '(no kind-0/3/10002 events, no bare kind-444 Welcomes on the relay)',
  );
}

/// Lowercase hex of [bytes].
String _hexLower(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// =============================================================================
// PHASE 6 helpers — non-admin leaves; admin observes
// =============================================================================

Future<
  ({
    SyntheticUser admin,
    SyntheticUser leaver,
    CircleWithMembersFfi adminResidual,
  })
>
_nonAdminLeavesAndAdminObserves({
  required ScenarioContext ctx,
  required SyntheticUser bob,
  required SyntheticUser carol,
  required CircleWithMembersFfi bobCircle,
  required CircleWithMembersFfi carolCircle,
}) async {
  // Identify the non-admin from Bob's residual-group view (Carol's
  // and Bob's views agree on the admin set per `select_successor`'s
  // determinism — the lex-smallest of {bob, carol} is admin).
  final bobIsAdmin = bobCircle.members.firstWhere(
    (m) => m.pubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
  ).isAdmin;

  // Drive the non-admin's leave via FFI, then drive the admin's
  // drain until the leaver's pubkey is gone.
  final SyntheticUser nonAdmin;
  final SyntheticUser admin;
  final CircleWithMembersFfi adminCircle;
  if (bobIsAdmin) {
    nonAdmin = carol;
    admin = bob;
    adminCircle = bobCircle;
  } else {
    nonAdmin = bob;
    admin = carol;
    adminCircle = carolCircle;
  }
  debugPrint(
    '[e2e_combined] PHASE 6 — ${nonAdmin.label} leaves '
    '(${admin.label} remains admin).',
  );

  // Choose the non-admin's circle handle (the up-to-date residual
  // view from the previous phase).
  final nonAdminCircle = nonAdmin == bob ? bobCircle : carolCircle;
  await nonAdmin.leaveAsNonAdmin(
    circle: nonAdminCircle,
    relay: ctx.relay,
  );

  // Admin drains until the leaver's pubkey is gone. The nostr/MLS
  // group id is stable across rounds, so the drain filter and the
  // getCircle handle both come from the initial `adminCircle`.
  final leaverHex = nonAdmin.pubkeyHex.toLowerCase();
  final mlsGroupId = adminCircle.circle.mlsGroupId;
  bool stillHasLeaver(CircleWithMembersFfi c) =>
      c.members.any((m) => m.pubkey.toLowerCase() == leaverHex);

  final current = await _pollUntil<CircleWithMembersFfi>(
    describe:
        '${admin.label} observing non-admin ${nonAdmin.label} leave — '
        'leaver should vanish from the member list',
    probe: () async {
      final summary = await admin.drainPendingCommits(
        relay: ctx.relay,
        circle: adminCircle,
      );
      final refreshed = await admin.getCircle(mlsGroupId);
      if (refreshed == null) {
        throw StateError(
          '[e2e_combined:${admin.label}] circle vanished from local MDK '
          'during non-admin leave drain.',
        );
      }
      debugPrint(
        '[e2e_combined:${admin.label}] post-leave drain '
        'groupUpdates=${summary.groupUpdatesProcessed} '
        'members=${refreshed.members.length} '
        'stillHasLeaver=${stillHasLeaver(refreshed)}',
      );
      return refreshed;
    },
    satisfied: (c) => !stillHasLeaver(c),
  );
  expect(
    current.members.length,
    equals(1),
    reason:
        '[e2e_combined:${admin.label}] residual member count after '
        'non-admin left is ${current.members.length}, expected exactly 1 '
        '(the admin themselves).',
  );
  expect(
    current.members.first.pubkey.toLowerCase(),
    equals(admin.pubkeyHex.toLowerCase()),
    reason:
        '[e2e_combined:${admin.label}] sole remaining member is not the '
        'admin — `leaveAsNonAdmin` evicted the wrong pubkey.',
  );
  debugPrint('[e2e_combined] PHASE 6 complete.');
  // `current` is the admin's up-to-date 1-member residual circle —
  // exactly the handle Phase 7 publishes its post-removal location to.
  return (admin: admin, leaver: nonAdmin, adminResidual: current);
}

// =============================================================================
// PHASE 7 helpers — forward secrecy after removal
// =============================================================================

/// Asserts the core Marmot/MLS + Haven privacy guarantee that a member
/// REMOVED from a circle cannot decrypt messages sent AFTER their
/// removal.
///
/// ## What this proves (and the honest scope)
///
/// The [admin] (sole remaining member) publishes a FRESH kind-445
/// location on its current, post-removal epoch. The evicted [leaver]
/// then attempts to decrypt it via the same drain/apply path a real
/// client uses. The leaver MUST NOT decrypt it.
///
/// This asserts the end-to-end "removed member cannot read post-removal
/// traffic" property. In Haven that holds via the COMBINATION of two
/// real, user-facing mechanisms:
///   1. `leaveAsNonAdmin` → `complete_leave` purges the leaver's local
///      MDK group state (forward-secrecy-on-leave), so there is no key
///      material to decrypt with; and
///   2. the admin's SelfRemove commit advanced the group to a new epoch
///      whose secrets the leaver never held.
///
/// It deliberately does NOT assert the narrower "even with retained
/// pre-removal state, the ratchet alone blocks it" property — Haven's
/// purge-on-leave makes that moot, and keeping the leaver's state alive
/// just to test the ratchet in isolation would not reflect production.
///
/// ## Why this is the inverse of Phase 4
///
/// Phase 4 already proved that while the leaver was a member, cross-peer
/// decrypt worked (it read the admin's locations). This is the contrast:
/// the SAME publish→relay→fetch→decrypt pipeline, the same admin sender,
/// now yields nothing for the leaver after removal.
///
/// ## Robustness
///
/// A null / `Unprocessable` / `PreviouslyFailed` result and a thrown FFI
/// error ALL legitimately mean "cannot decrypt" (the wiped group and the
/// epoch advance both manifest that way), and the drain path
/// (`_applyEventsInOrder`) already absorbs each into "not decrypted"
/// without adding the sender. So the assertion is simply "the admin's
/// pubkey is absent from the leaver's decrypted set", which fails ONLY
/// if the leaver actually decrypted post-removal traffic.
Future<void> _assertForwardSecrecyAfterRemoval({
  required ScenarioContext ctx,
  required SyntheticUser admin,
  required SyntheticUser leaver,
  required CircleWithMembersFfi adminResidual,
}) async {
  final adminHex = admin.pubkeyHex.toLowerCase();
  debugPrint(
    '[e2e_combined] PHASE 7 — forward secrecy after removal: '
    '${admin.label} publishes a post-removal location; '
    '${leaver.label} (evicted) must not decrypt it.',
  );

  // Step 1 — the admin publishes a FRESH location on its current,
  // post-removal epoch. MLS encrypts to the current epoch secrets
  // regardless of member count, so a 1-member residual group still
  // yields a valid kind-445 the leaver never had keys for. The admin
  // is dynamically Bob or Carol; map to that role's sentinel coords
  // (the values are immaterial to this assertion — we test decrypt
  // success/failure, not coordinates — but staying on-sentinel keeps
  // the wire consistent with Phase 4).
  final (double adminLat, double adminLon) = admin.label == 'bob'
      ? (bobFakeLatitude, bobFakeLongitude)
      : (carolFakeLatitude, carolFakeLongitude);
  final eventId = await admin.publishLocation(
    circle: adminResidual,
    latitude: adminLat,
    longitude: adminLon,
    relay: ctx.relay,
  );

  // Step 2 — confirm the post-removal event is actually on the relay
  // before the leaver attempts it, so a "leaver can't decrypt" pass
  // can never be vacuous (event never published / wrong group id).
  await ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      'ids': <String>[eventId],
      'limit': 1,
    },
    timeout: const Duration(seconds: 15),
  );

  // Step 3 — the evicted leaver attempts to decrypt via the SAME
  // drain/apply path a live client uses. `complete_leave` purged the
  // leaver's local group state, so MDK has nothing to decrypt with;
  // the drain absorbs the null/Unprocessable/throw without adding the
  // admin to its decrypted set. Poll a few times so a slow relay
  // round-trip cannot produce a false "can't decrypt".
  var decryptedAdmin = false;
  var lastKeys = const <String>[];
  for (var attempt = 0; attempt < 4 && !decryptedAdmin; attempt++) {
    // `drainPendingCommits` only reads `nostrGroupId`/`mlsGroupId` from
    // the passed circle to build the relay filter and FFI lookup; both
    // are stable across the leave, so reusing the admin's `adminResidual`
    // handle here just targets the right group — the decrypt itself runs
    // against the LEAVER's own (now-purged) MDK state.
    final summary = await leaver.drainPendingCommits(
      relay: ctx.relay,
      circle: adminResidual,
    );
    lastKeys = summary.decryptedLocations.keys.toList();
    decryptedAdmin =
        summary.decryptedLocationSenders.contains(adminHex) ||
        summary.decryptedLocations.containsKey(adminHex);
    if (decryptedAdmin) break;
    debugPrint(
      '[e2e_combined:${leaver.label}] PHASE 7 attempt $attempt — '
      'post-removal event not decrypted (expected); '
      'decryptFailed=${summary.decryptFailed} '
      'locations=${summary.locationsProcessed}',
    );
    await Future<void>.delayed(_convergencePollInterval);
  }

  expect(
    decryptedAdmin,
    isFalse,
    reason:
        'FORWARD SECRECY VIOLATION: ${leaver.label} was removed from the '
        "circle yet decrypted ${admin.label}'s post-removal kind-445 "
        '(event ${_redactPk(eventId)}). A removed member MUST NOT read '
        'messages sent after their removal — broken if `complete_leave` '
        "failed to purge the leaver's MLS state or the post-removal "
        'epoch advance did not take effect. Leaver decrypted-location '
        'keys: ${lastKeys.map(_redactPk).toList()}.',
  );
  debugPrint(
    '[e2e_combined] PHASE 7 complete — ${leaver.label} could NOT decrypt '
    "${admin.label}'s post-removal location (forward secrecy holds).",
  );
}

// =============================================================================
// Misc helpers
// =============================================================================

/// Asserts that [locs] contains an entry for [senderPubkeyHex] with
/// lat/lon values equal to [expectedLatitude] / [expectedLongitude]
/// within [_coordEpsilon].
///
/// A mismatch signals a coordinate corruption bug that the simpler
/// sender-presence check would miss.
void _assertMemberLocationCoordinates({
  required String label,
  required List<MemberLocation> locs,
  required String senderPubkeyHex,
  required double expectedLatitude,
  required double expectedLongitude,
}) {
  const epsilon = _coordEpsilon;
  final entry = locs.where(
    (l) => l.pubkey.toLowerCase() == senderPubkeyHex.toLowerCase(),
  ).firstOrNull;
  expect(
    entry,
    isNotNull,
    reason:
        '$label: no MemberLocation entry found for sender '
        "${senderPubkeyHex.substring(0, 8)}… in alice's "
        'memberLocationsProvider.',
  );
  if (entry == null) return; // unreachable after expect above; satisfies type
  expect(
    (entry.latitude - expectedLatitude).abs(),
    lessThan(epsilon),
    reason:
        '$label: latitude mismatch — got ${entry.latitude}, '
        'expected $expectedLatitude (within $epsilon). '
        'Decrypt succeeded but returned corrupt coordinates.',
  );
  expect(
    (entry.longitude - expectedLongitude).abs(),
    lessThan(epsilon),
    reason:
        '$label: longitude mismatch — got ${entry.longitude}, '
        'expected $expectedLongitude (within $epsilon). '
        'Decrypt succeeded but returned corrupt coordinates.',
  );
}

/// Asserts that [coords] (keyed by lowercase sender pubkey hex) contains
/// an entry for [senderPubkeyHex] with coordinates matching
/// [expectedLatitude] / [expectedLongitude] within [_coordEpsilon].
///
/// Used on the synthetic-peer side (Bob and Carol's FFI drain results).
/// A mismatch signals a coordinate corruption bug invisible to the
/// sender-presence check in `_drainUntilLocationsVisible`.
void _assertDecryptedCoords({
  required String label,
  required Map<String, DecryptedCoords> coords,
  required String senderPubkeyHex,
  required double expectedLatitude,
  required double expectedLongitude,
}) {
  const epsilon = _coordEpsilon;
  final key = senderPubkeyHex.toLowerCase();
  final entry = coords[key];
  expect(
    entry,
    isNotNull,
    reason:
        '$label: no decrypted coordinates found for sender '
        '${senderPubkeyHex.substring(0, 8)}… — either the drain '
        'did not yield a location result or the summary map was not '
        'accumulated correctly.',
  );
  if (entry == null) return; // unreachable after expect above; satisfies type
  expect(
    (entry.latitude - expectedLatitude).abs(),
    lessThan(epsilon),
    reason:
        '$label: latitude mismatch — got ${entry.latitude}, '
        'expected $expectedLatitude (within $epsilon). '
        'Decrypt succeeded but returned corrupt coordinates.',
  );
  expect(
    (entry.longitude - expectedLongitude).abs(),
    lessThan(epsilon),
    reason:
        '$label: longitude mismatch — got ${entry.longitude}, '
        'expected $expectedLongitude (within $epsilon). '
        'Decrypt succeeded but returned corrupt coordinates.',
  );
}

void _assertCircleHasMembers({
  required String label,
  required CircleWithMembersFfi circle,
  required List<String> expectedPubkeyHexes,
}) {
  final expectedSet = expectedPubkeyHexes.map((p) => p.toLowerCase()).toSet();
  final actualSet = circle.members.map((m) => m.pubkey.toLowerCase()).toSet();
  expect(
    actualSet,
    equals(expectedSet),
    reason:
        '$label: MDK member-set mismatch after acceptInvitation. '
        'Expected ${expectedSet.length} members; got ${actualSet.length}. '
        "This is a strong signal that either the gift-wrap's inner "
        'Welcome targeted the wrong KeyPackage (MIP-02 / NIP-59 '
        'regression) or MDK failed to fully apply the create-circle '
        "commit on $label's side.",
  );
}

/// Reads Alice's production [circlesProvider] and asserts that it
/// contains exactly one circle whose [Circle.displayName] is
/// [_circleName] ("Family") with exactly the [expectedMemberPubkeyHexes]
/// set as accepted members.
///
/// Call this after Phase 4 (locations converged) to prove Alice's
/// production circle/evolution state is correct end-to-end — not just
/// the `memberLocationsProvider` — via the same `ProviderScope`
/// container the production app uses.
Future<void> _assertAliceCirclesProviderHasFamily({
  required WidgetTester tester,
  required List<String> expectedMemberPubkeyHexes,
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(circlesProvider);
  final circles = await container.read(circlesProvider.future);

  expect(
    circles,
    hasLength(1),
    reason:
        "Alice's circlesProvider must contain exactly 1 circle after "
        'Phase 4 (3-way location sharing converged). Got '
        '${circles.length}. Either circle creation did not persist '
        'into the production CircleService or the provider returned '
        'an error-fallback empty list.',
  );

  final family = circles.first;
  expect(
    family.displayName,
    equals(_circleName),
    reason:
        "The single circle in Alice's circlesProvider must be named "
        '"$_circleName". Got "${family.displayName}". A name mismatch '
        'indicates the production CircleService is returning a stale or '
        'different circle.',
  );

  final expectedSet =
      expectedMemberPubkeyHexes.map((p) => p.toLowerCase()).toSet();
  final actualSet =
      family.members.map((m) => m.pubkey.toLowerCase()).toSet();
  expect(
    actualSet,
    equals(expectedSet),
    reason:
        "Alice's circlesProvider returned a member set "
        '(${actualSet.length} members) that does not match the '
        'expected 3-member set ${expectedSet.map(_redactPk).toList()}. '
        'Either Bob or Carol did not appear as an accepted member '
        'in the production CircleService after both accepted their '
        'invitations.',
  );

  // Every member surfaced by the production CircleService is always
  // treated as accepted (visible circles only contain accepted members
  // — see `NostrCircleService._convertMember`). Asserting this here
  // makes the conversion contract explicit and catches any future
  // regression that would expose pending/declined members through
  // `getVisibleCircles`.
  for (final member in family.members) {
    expect(
      member.status,
      equals(MembershipStatus.accepted),
      reason:
          'All members of a visible circle must have '
          '`MembershipStatus.accepted` — '
          '${_redactPk(member.pubkey)} has ${member.status} instead.',
    );
  }

  debugPrint(
    '[e2e_combined:alice] circlesProvider assertion OK — '
    '"$_circleName" with ${family.members.length} accepted members.',
  );
}

/// Reads Alice's production [circlesProvider] and asserts that it is
/// empty — proving the production AdminHandoff leave path updated her
/// real circle state, not merely that the circle tile text disappeared
/// from the UI widget tree.
///
/// Call this immediately after [_aliceLeavesViaUi] returns.
/// Corroborates — at the production-provider layer — that Alice's
/// AdminHandoff leave removed the circle from her real state.
///
/// ## Soundness note (why this is a CORROBORATING, not authoritative,
/// check)
///
/// `circlesProvider` is a `FutureProvider` that catches every error
/// from `getVisibleCircles()` and returns `[]` (so the UI degrades
/// gracefully when the FFI/keyring is unavailable). That means an
/// *empty* result is ambiguous: "Alice genuinely left" vs. "the read
/// errored." We therefore do NOT treat provider-empty as the
/// authoritative proof of the leave. The authoritative, non-vacuous
/// proof lives in `_assertResidualGroupAfterHandoff` (Phase 5) and
/// `_assertForwardSecrecyAfterRemoval` (Phase 7), which read the
/// MLS member set through the FFI (errors surface as exceptions, not
/// swallowed). This check adds value as a CONTRAST against
/// `_assertAliceCirclesProviderHasFamily` (Phase 4), which already
/// proved the provider returns real data for this circle: the provider
/// went from "Family with 3 members" to empty across the leave.
///
/// We poll briefly so a slow `complete_leave` → SQLCipher flush retries
/// rather than failing; if the circle is still present the assertion
/// fails fast with an actionable message.
Future<void> _assertAliceCirclesProviderIsEmpty({
  required WidgetTester tester,
}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );
  final circles = await _pollUntil<List<Circle>>(
    describe:
        "Alice's circlesProvider should be empty after her AdminHandoff "
        'leave (corroborating the FFI residual-group proof)',
    probe: () async {
      container.invalidate(circlesProvider);
      return container.read(circlesProvider.future);
    },
    satisfied: (circles) => circles.isEmpty,
    budget: const Duration(seconds: 15),
  );

  expect(
    circles,
    isEmpty,
    reason:
        "Alice's circlesProvider must be empty after she left the circle "
        'via the UI (AdminHandoff path). Got ${circles.length} circle(s). '
        'Either `complete_leave` did not remove the circle from the '
        'production CircleService, or the provider was not invalidated '
        'after the leave.',
  );

  debugPrint(
    '[e2e_combined:alice] circlesProvider empty assertion OK — '
    'production leave path updated real state.',
  );
}

/// Cached Alice pubkey hex derived from the sentinel seed.
///
/// Computed once at `setUpAll` via `_prepareAlicePubkey` so the sync
/// helper `_alicePubkeyHex` can return it without awaiting the FFI
/// from inside the test body. Calling `_alicePubkeyHex` before
/// `_prepareAlicePubkey` has resolved is a programmer error and
/// throws a `StateError` with a clear message.
String? _aliceCachedPubkeyHex;

String _alicePubkeyHex() {
  final cached = _aliceCachedPubkeyHex;
  if (cached == null) {
    throw StateError(
      '_alicePubkeyHex() called before _prepareAlicePubkey() resolved',
    );
  }
  return cached;
}

Future<void> _prepareAlicePubkey() async {
  final ident = await TestUser.derivePubkeyAndNpub(aliceSeed);
  _aliceCachedPubkeyHex = ident.pubkeyHex;
}

String _redactPk(String hex) =>
    hex.length <= 8 ? hex : '${hex.substring(0, 8)}…';

/// Reads the current MLS epoch for [mlsGroupId] from Alice's production
/// `CircleManagerFfi`.
///
/// Alice's `CircleManagerFfi` lives inside `NostrCircleService`, which is
/// obtained from Alice's production `ProviderScope` container. This is the
/// authoritative peer-manager instance the production app uses — the same one
/// that runs `createCircle`, `addMember`, and all other circle operations.
///
/// `getCircleManagerFfi()` is defined on [NostrCircleService]; since the
/// production `circleServiceProvider` always returns a [NostrCircleService]
/// instance, the cast is safe in the E2E context. The integration test
/// process does not override `circleServiceProvider` (only
/// `onboardingControllerProvider` and `locationServiceProvider` are overridden
/// in the widget pump). If the cast fails it throws `TypeError` immediately
/// — an unambiguous signal that the service was swapped out.
///
/// `groupEpochForTest` is debug-gated (compiled out of release builds); it is
/// safe to call only in tests and debug builds.
///
/// Throws if the group does not exist in Alice's MDK instance or the FFI call
/// fails.
Future<int> _aliceEpochForTest(
  WidgetTester tester,
  List<int> mlsGroupId,
) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );
  // Cast to the concrete type to reach getCircleManagerFfi(). The
  // circleServiceProvider always returns a NostrCircleService in production
  // and in this test (no override on circleServiceProvider here). The cast
  // throws TypeError if that changes, giving an unambiguous failure message.
  final circleService =
      container.read(circleServiceProvider) as NostrCircleService;
  final manager = await circleService.getCircleManagerFfi();
  final epoch = await manager.groupEpochForTest(mlsGroupId: mlsGroupId);
  return epoch.toInt();
}
