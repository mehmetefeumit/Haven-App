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
///   `evolutionPollerProvider`, the new `_persistDecryptedLocation`
///   shared helper between fetcher and poller paths.
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
///
/// ## Scenario phases
///
/// 1. **setUpAll**: Rust bridge + in-memory keyring + relay override,
///    pre-seed Alice's identity into `flutter_secure_storage`,
///    bootstrap Bob and Carol as [SyntheticUser] instances (publishes
///    their KeyPackages to the hermetic strfry).
/// 2. **Pump HavenApp**: lands on `MapShell` with Alice's identity
///    loaded and the geolocator replaced by the deterministic fake.
/// 3. **Alice creates a 3-member circle inviting Bob and Carol** via
///    the production UI. Two kind-1059 gift-wraps land on strfry; the
///    test gates on both via `TestRelay.firstWhere`.
/// 4. **Bob and Carol accept via FFI**:
///    `SyntheticUser.acceptInvitationViaRelay` reproduces the
///    `InvitationPoller → process_gift_wrapped_invitation →
///    accept_invitation` chain without the UI. Each asserts that the
///    resulting MDK member set has all three peers.
/// 5. **Three-way location sharing**: Alice's `locationPublisherProvider`
///    fires, Bob and Carol publish via FFI, all three drain the
///    relay. Alice's `memberLocationsProvider` is the source of truth
///    for the UI side; Bob's and Carol's FFI `getMembers` view is the
///    source of truth for the synthetic-peer side.
/// 6. **Alice (admin) leaves via UI**: `LeavePlan::AdminHandoff` runs
///    underneath, emitting the three-commit sequence
///    `AdminHandoff → SelfDemote → SelfRemove`. Bob and Carol drain
///    the commits via FFI. Exactly one of them ends up `isAdmin=true`
///    (lex-smallest non-self per `select_successor`).
/// 7. **Non-admin leaves via FFI**: the residual member who is NOT
///    admin calls `SyntheticUser.leaveAsNonAdmin`; the remaining
///    admin drains the SelfRemove and asserts the leaver is gone.
///
/// ## Acceptance hooks
///
/// Reverting any of the following to a no-op turns this scenario red:
/// - `NostrCircleService.createCircle` — gift-wrap waits time out.
/// - `signKeyPackageEvent` — Alice's circle-creation flow fails KP
///   validation for Bob/Carol.
/// - `CircleManagerFfi.acceptInvitation` — Bob's and Carol's MDK
///   member-set assertions fail (still 1 member after accept).
/// - `encryptLocation` — Alice's relay-side wait for kind-445 fires.
/// - `decryptLocation` — neither side surfaces the other's location.
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
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show FilledButton, TextButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart' show CircleWithMembersFfi;
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/diagnostics.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/sheet_helpers.dart';
import '_lib/synthetic_user.dart';
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
        // PHASE 2 — Alice creates the three-member circle via UI.
        // -----------------------------------------------------------
        await _aliceCreatesThreeMemberCircle(
          tester: tester,
          ctx: ctx,
          bob: bob,
          carol: carol,
        );

        // -----------------------------------------------------------
        // PHASE 3 — Bob and Carol accept their invitations via FFI.
        //
        // The production InvitationPoller + accept_invitation chain
        // runs identically; only the UI rebuild is skipped. After
        // both helpers return, each peer's local MDK state has
        // applied Alice's Welcome and the three-member set is
        // visible.
        // -----------------------------------------------------------
        // No explicit timeout — the default (90s) matches
        // `_giftWrapDeadline` so we don't repeat ourselves.
        final bobCircle = await bob.acceptInvitationViaRelay(
          relay: ctx.relay,
        );
        final carolCircle = await carol.acceptInvitationViaRelay(
          relay: ctx.relay,
        );
        _assertCircleHasMembers(
          label: 'bob',
          circle: bobCircle,
          expectedPubkeyHexes: <String>[
            _alicePubkeyHex(),
            bob.pubkeyHex,
            carol.pubkeyHex,
          ],
        );
        _assertCircleHasMembers(
          label: 'carol',
          circle: carolCircle,
          expectedPubkeyHexes: <String>[
            _alicePubkeyHex(),
            bob.pubkeyHex,
            carol.pubkeyHex,
          ],
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
        final handoffInbox = _ArrivalOrderedInbox(
          relay: ctx.relay,
          nostrGroupId: bobCircle.circle.nostrGroupId,
        );
        final CircleWithMembersFfi residualBobCircle;
        final CircleWithMembersFfi residualCarolCircle;
        try {
          await _aliceLeavesViaUi(tester: tester);
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
        // -----------------------------------------------------------
        await _nonAdminLeavesAndAdminObserves(
          ctx: ctx,
          bob: bob,
          carol: carol,
          bobCircle: residualBobCircle,
          carolCircle: residualCarolCircle,
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
      }
    },
    timeout: const Timeout(_outerTestTimeout),
  );
}

// =============================================================================
// PHASE 2 helpers — Alice creates a 3-member circle through the UI
// =============================================================================

Future<void> _aliceCreatesThreeMemberCircle({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required SyntheticUser bob,
  required SyntheticUser carol,
}) async {
  // Both peers' KeyPackages were published synchronously in
  // setUpAll — assert their availability before Alice opens
  // CreateCirclePage so we never race the relay's session-start
  // latency.
  await Future.wait<void>(<Future<void>>[
    waitForKeyPackage(
      relay: ctx.relay,
      authorPubkeyHex: bob.pubkeyHex,
    ).then((_) {}),
    waitForKeyPackage(
      relay: ctx.relay,
      authorPubkeyHex: carol.pubkeyHex,
    ).then((_) {}),
  ]);

  // Open BOTH gift-wrap subscriptions BEFORE Alice taps Create so
  // we never miss the events. NIP-59 gift-wraps use ephemeral outer
  // keys, so we filter by recipient `#p` tag rather than by author.
  final bobGiftWrap = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: bob.pubkeyHex,
    timeout: _giftWrapDeadline,
  );
  final carolGiftWrap = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: carol.pubkeyHex,
    timeout: _giftWrapDeadline,
  );

  // Expand the draggable bottom sheet to bring the empty-state CTA
  // into the viewport. The retry-aware helper avoids the velocity-
  // tracker flake the synthetic-drag pattern is prone to on slow
  // CI emulators (see `_lib/sheet_helpers.dart`).
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.byKey(WidgetKeys.circlesCreateCta),
  );
  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  // pumpUntilFound, not pumpAndSettle. MapShell stays in the
  // Navigator's back stack while CreateCirclePage is on top, and
  // MapShell's periodic timers continue scheduling frames from the
  // back stack — pumpAndSettle would never see an empty frame queue
  // and would hang on its internal 10-minute fallback.
  await pumpUntilFound(
    tester,
    find.byType(CreateCirclePage),
    description: 'CreateCirclePage after tapping Create Circle CTA',
  );

  // Member selection — enter both npubs and submit each via the
  // IME done action. Between npub entries we pump a bounded handful
  // of frames so the IME-routed text + done action work their way
  // through the pipeline; we deliberately do not wait on the
  // member-chip becoming visible because the chip has no stable
  // WidgetKey today, and pumpAndSettle is unsafe (see comment
  // above). The Continue button's enabled state is the next gating
  // observable; we drive that via pumpUntilCondition below.
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    bob.npub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    carol.npub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  // Wait for the Continue button to be tappable (visible AND
  // enabled — its enabled state flips once both npubs validate
  // against the relay's KP fetch). pumpUntilCondition surfaces a
  // clean failure if validation never completes.
  await pumpUntilCondition(
    tester,
    () {
      final btn = find.byKey(WidgetKeys.createCircleContinue);
      if (btn.evaluate().isEmpty) return false;
      final widget = tester.widget(btn);
      if (widget is FilledButton) return widget.onPressed != null;
      // Defensive: if the underlying widget type changes, fall back
      // to "found" so the test surfaces the routing miss further on.
      return true;
    },
    description:
        'createCircleContinue enabled after both npubs validate',
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
  // After Create, the navigator pops back to MapShell. Wait for the
  // MapShell to be on top again — same rationale as above for
  // avoiding pumpAndSettle.
  await pumpUntilFound(
    tester,
    find.byType(MapShell),
    description: 'MapShell after Create Circle tap',
  );
  expect(
    find.textContaining(_circleName),
    findsAtLeastNWidgets(1),
    reason:
        'After Create Circle returns, either the SnackBar or the new '
        'circle tile must be visible on the map shell.',
  );

  // Both gift-wraps must have landed on the relay; without them the
  // synthetic peers' acceptInvitationViaRelay would hang on the
  // `firstWhere` lookup.
  await Future.wait<void>(<Future<void>>[
    bobGiftWrap.then((_) {}),
    carolGiftWrap.then((_) {}),
  ]);

  debugPrint('[e2e_combined:alice] PHASE 2 complete (3-member circle).');
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
  // TODO(efe): wait-for-epoch. When `wait_for_epoch_for_test`
  // (haven/rust_builder/src/api.rs:3143) is wired up, replace the
  // retry budget with a deterministic epoch-target wait so peer-
  // location-publish races become impossible by construction.
  // -----------------------------------------------------------------
  final expectedPeerSet = <String>{
    bob.pubkeyHex.toLowerCase(),
    carol.pubkeyHex.toLowerCase(),
  };
  var aliceMissingPeers = Set<String>.of(expectedPeerSet);
  for (
    var attempt = 0;
    attempt < 8 && aliceMissingPeers.isNotEmpty;
    attempt++
  ) {
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

    final present = locs.map((l) => l.pubkey.toLowerCase()).toSet();
    aliceMissingPeers = aliceMissingPeers.difference(present);
    if (aliceMissingPeers.isEmpty) break;

    debugPrint(
      '[e2e_combined:alice] PHASE 4 attempt $attempt — '
      'memberLocationsProvider missing ${aliceMissingPeers.length} peers',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    aliceMissingPeers,
    isEmpty,
    reason:
        "alice: memberLocationsProvider did not surface every peer's "
        'location within the retry budget. Either decryptLocation '
        "returned null, the MLS epoch race didn't converge, or the "
        'shared `_persistDecryptedLocation` helper in '
        'location_sharing_service.dart has regressed (fetch vs poller '
        'race).',
  );

  // -----------------------------------------------------------------
  // Step 4 — Bob and Carol observe each other AND Alice via FFI.
  // The drain helper fetches every kind-445 on the relay (filtered
  // by `#h=nostr_group_id`) and decrypts each through their MDK.
  // After draining, the peer's local cache holds every successfully-
  // decrypted location.
  // -----------------------------------------------------------------
  await _drainUntilLocationsVisible(
    peer: bob,
    relay: ctx.relay,
    circle: bobCircle,
    expectedSenders: <String>{
      _alicePubkeyHex().toLowerCase(),
      carol.pubkeyHex.toLowerCase(),
    },
  );
  await _drainUntilLocationsVisible(
    peer: carol,
    relay: ctx.relay,
    circle: carolCircle,
    expectedSenders: <String>{
      _alicePubkeyHex().toLowerCase(),
      bob.pubkeyHex.toLowerCase(),
    },
  );

  debugPrint('[e2e_combined] PHASE 4 complete (3-way locations).');
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
/// Accumulates senders across drain iterations so we converge as
/// new peers' locations land on subsequent fetches, even when an
/// earlier drain only saw a subset.
Future<void> _drainUntilLocationsVisible({
  required SyntheticUser peer,
  required TestRelay relay,
  required CircleWithMembersFfi circle,
  required Set<String> expectedSenders,
}) async {
  final deadline = DateTime.now().add(_peerConvergenceBudget);
  final accumulatedSenders = <String>{};
  while (DateTime.now().isBefore(deadline)) {
    final summary = await peer.drainPendingCommits(
      relay: relay,
      circle: circle,
    );
    accumulatedSenders.addAll(summary.decryptedLocationSenders);
    final missing = expectedSenders.difference(accumulatedSenders);
    if (missing.isEmpty) {
      debugPrint(
        '[e2e_combined:${peer.label}] location convergence ok '
        '(${accumulatedSenders.length}/${expectedSenders.length} '
        'distinct senders decrypted)',
      );
      return;
    }
    debugPrint(
      '[e2e_combined:${peer.label}] location convergence pending — '
      'missing ${missing.length} senders',
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  throw StateError(
    '[e2e_combined:${peer.label}] location convergence timeout '
    '(accumulated ${accumulatedSenders.length} distinct senders, '
    'expected ${expectedSenders.length}, within '
    '${_peerConvergenceBudget.inSeconds}s)',
  );
}

// =============================================================================
// PHASE 5 helpers — Alice leaves through the UI; Bob and Carol observe
// =============================================================================

Future<void> _aliceLeavesViaUi({required WidgetTester tester}) async {
  final detailsButton = find.byTooltip('Circle details');
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        "After PHASE 2/4, Alice's selected-circle header with its "
        '"Circle details" info button must be visible in the bottom sheet.',
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
  // Wait for the confirmation dialog's Leave TextButton to appear.
  await pumpUntilFound(
    tester,
    find.widgetWithText(TextButton, 'Leave'),
    description: 'Leave confirmation dialog after tapping Leave Circle',
  );

  // Confirmation dialog. The "Leave" TextButton is distinct from the
  // dialog title "Leave Circle"; widgetWithText is the unambiguous
  // selector.
  final leaveConfirm = find.widgetWithText(TextButton, 'Leave');
  await tester.tap(leaveConfirm);

  // FFI: planLeave (AdminHandoff) → proposeAdminHandoff → publish →
  // finalize → proposeSelfDemote → publish → finalize → proposeLeave →
  // publish → completeLeave. Three relay round-trips.
  //
  // pumpUntilGone, not pumpAndSettle: the dialog pops immediately
  // when the tap is processed, then the async FFI chain begins.
  // pumpAndSettle can see a momentarily-empty frame queue BETWEEN
  // the dialog close and the next FFI await, settle prematurely,
  // and let the next assertion fire while the chain is still in
  // flight. Waiting on the actual observable — the circle name
  // leaving the widget tree — gates the next assertion on the work
  // being done.
  await pumpUntilGone(
    tester,
    find.text(_circleName),
    timeout: const Duration(seconds: 60),
    description:
        'circle "$_circleName" tile disappearing after Alice taps Leave',
  );

  expect(find.byType(MapShell), findsOneWidget);
  expect(
    find.text(_circleName),
    findsNothing,
    reason:
        'After AdminHandoff completes, the circle "$_circleName" must '
        "no longer appear in Alice's circle list.",
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
    final hex = nostrGroupId
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
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

/// Drives both peers through the admin-handoff and reconciles the
/// competing SelfRemove commits, returning each peer's up-to-date
/// circle once they have provably converged onto the SAME MLS branch.
///
/// ## Why this is more than "apply the commits"
///
/// `LeavePlan::AdminHandoff` ends with a SelfRemove PROPOSAL. Per
/// RFC 9420 §12.1.2 (and matching whitenoise), EVERY remaining member
/// auto-commits it, so Bob and Carol each mint a competing epoch-3→4
/// commit — a transient fork. Their member sets coincide (both
/// removed Alice), so a member-set check alone cannot tell a
/// reconciled group from a forked one. MDK resolves the fork
/// deterministically: `is_better_candidate` elects one winner and the
/// loser rolls its finalized commit back (via the epoch snapshot
/// created at merge) and adopts the winner. That only happens when
/// the loser re-processes the winner's commit, so this loop keeps
/// applying the shared inbox — which buffers BOTH competing commits —
/// to BOTH peers until reconciliation completes.
///
/// ## Convergence is verified behaviorally — no internal-state FFI
///
/// Two peers can share a member set yet sit on different epoch-4
/// branches (different exporter secrets). Rather than expose MLS
/// internals across the FFI, we prove convergence the way it actually
/// matters to a user: the publisher emits a fresh location and the
/// observer must DECRYPT it. That only succeeds if they share the
/// epoch-4 secrets, i.e. the same branch. Pre-handoff locations are
/// unprocessable at the new epoch, so a positive decrypt is
/// unambiguous. This keeps the entire fix inside the integration test
/// — zero production surface, zero secret exposure.
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
  final bobHex = bob.pubkeyHex.toLowerCase();
  final deadline = DateTime.now().add(_peerConvergenceBudget);
  var bobCurrent = bobCircle;
  var carolCurrent = carolCircle;
  var probePublished = false;

  while (DateTime.now().isBefore(deadline)) {
    // Re-apply the shared inbox to BOTH peers each round. The loser
    // re-processes the winner's competing commit here and MDK rolls
    // it onto the winning branch.
    await bob.applyArrivalOrdered(inbox.snapshot(), relay: relay);
    final carolSummary = await carol.applyArrivalOrdered(
      inbox.snapshot(),
      relay: relay,
    );

    final bobRefreshed = await bob.getCircle(mlsGroupId);
    final carolRefreshed = await carol.getCircle(mlsGroupId);
    if (bobRefreshed == null || carolRefreshed == null) {
      throw StateError(
        '[e2e_combined] a peer circle vanished during handoff '
        'reconciliation — a peer was inadvertently removed.',
      );
    }
    bobCurrent = bobRefreshed;
    carolCurrent = carolRefreshed;

    final membersConverged =
        _residualMembersOk(bobCurrent, aliceHex) &&
        _residualMembersOk(carolCurrent, aliceHex);

    // Once the probe is on the wire, watch Carol's drains for Bob's
    // fresh location: decrypting it proves a shared epoch-4 branch.
    final branchVerified =
        probePublished &&
        carolSummary.decryptedLocationSenders.contains(bobHex);

    debugPrint(
      '[e2e_combined] handoff reconcile: '
      'bobMembers=${bobCurrent.members.length} '
      'carolMembers=${carolCurrent.members.length} '
      'membersConverged=$membersConverged '
      'probePublished=$probePublished '
      'branchVerified=$branchVerified',
    );

    if (branchVerified) {
      debugPrint(
        '[e2e_combined] handoff fully reconciled — Bob and Carol on '
        'the same MLS branch (probe decrypted).',
      );
      return (bob: bobCurrent, carol: carolCurrent);
    }

    // Member sets agree: publish a single probe so the next rounds
    // can confirm the two peers truly share a branch.
    if (membersConverged && !probePublished) {
      await bob.publishLocation(
        circle: bobCurrent,
        latitude: bobFakeLatitude,
        longitude: bobFakeLongitude,
        relay: relay,
      );
      probePublished = true;
      debugPrint('[e2e_combined] convergence probe published by bob');
    }

    await Future<void>.delayed(const Duration(seconds: 3));
  }
  throw StateError(
    '[e2e_combined] handoff reconciliation timeout after '
    '${_peerConvergenceBudget.inSeconds}s — Bob and Carol did not '
    'converge onto a single MLS branch (member sets matched but the '
    'cross-branch probe never decrypted). The competing-commit '
    'reconciliation did not complete.',
  );
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

// =============================================================================
// PHASE 6 helpers — non-admin leaves; admin observes
// =============================================================================

Future<void> _nonAdminLeavesAndAdminObserves({
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

  // Admin drains until the leaver's pubkey is gone.
  final leaverHex = nonAdmin.pubkeyHex.toLowerCase();
  final deadline = DateTime.now().add(_peerConvergenceBudget);
  var current = adminCircle;
  var converged = false;
  while (DateTime.now().isBefore(deadline)) {
    final summary = await admin.drainPendingCommits(
      relay: ctx.relay,
      circle: current,
    );
    final refreshed = await admin.getCircle(current.circle.mlsGroupId);
    if (refreshed == null) {
      throw StateError(
        '[e2e_combined:${admin.label}] circle vanished from local MDK '
        'during non-admin leave drain.',
      );
    }
    current = refreshed;
    final stillHasLeaver = current.members.any(
      (m) => m.pubkey.toLowerCase() == leaverHex,
    );
    debugPrint(
      '[e2e_combined:${admin.label}] post-leave drain '
      'groupUpdates=${summary.groupUpdatesProcessed} '
      'members=${current.members.length} '
      'stillHasLeaver=$stillHasLeaver',
    );
    if (!stillHasLeaver) {
      converged = true;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }
  expect(
    converged,
    isTrue,
    reason:
        '[e2e_combined:${admin.label}] non-admin ${nonAdmin.label} still '
        'in member list after ${_peerConvergenceBudget.inSeconds}s of '
        'post-leave drain.',
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
}

// =============================================================================
// Misc helpers
// =============================================================================

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
