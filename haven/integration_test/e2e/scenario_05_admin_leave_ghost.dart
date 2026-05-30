/// Scenario 05 — two-process: Alice (sole admin) leaves the circle via the
/// production UI; Bob (non-admin member) observes her departure from his
/// member list.
///
/// This is the regression coverage for the upstream-supported admin-leave
/// flow. MDK's MIP-03 admin-gate (`mdk-core/src/groups.rs::leave_group`)
/// blocks an admin from emitting a raw SelfRemove proposal — admins MUST
/// `self_demote()` first. Haven's `LeavePlan::AdminHandoff`
/// (`haven-core/src/circle/leave.rs`) honours that contract: when a sole
/// admin taps Leave Circle, the manager promotes a deterministically
/// chosen successor (`proposeAdminHandoff`), then self-demotes
/// (`proposeSelfDemote`), then publishes the actual SelfRemove
/// (`proposeLeave`). All three commits flow through the same UI button
/// the non-admin path uses in `scenario_04` — there is no separate admin
/// affordance.
///
/// Setup (PHASE 1): inlined from `scenario_02` — Alice creates the
/// circle and invites Bob; Bob accepts. Duplicated deliberately so each
/// scenario is self-contained.
///
/// Test phase (PHASE 2):
///   - Alice navigates into the circle-details modal, taps Leave
///     Circle, confirms the dialog, and asserts the circle disappears
///     from her bottom sheet (same UX as scenario_04 from her side).
///   - Bob waits for kind-445 evolution events to land on the
///     hermetic strfry, then drives the production evolution poller
///     until Alice is no longer in his circle's member list.
///
/// Acceptance hooks:
///   - Reverting `LeavePlan::AdminHandoff` to skip `proposeAdminHandoff`
///     or `proposeSelfDemote` makes Alice's leave fail at MDK's
///     admin-gate; her bottom-sheet assertion times out and the
///     SnackBar surfaces the error.
///   - Reverting the relay publish path for any of the three commits
///     makes Bob's wait-for-eviction time out (the kind-445 stream
///     dries up before the membership transition lands).
///   - Reverting `CircleManager::remove_member` post-processing so the
///     successor never finalizes the leave commit makes Bob's local
///     member-list assertion fail (Alice never leaves his roster).
library;

import 'package:flutter/material.dart'
    show DraggableScrollableSheet, TextButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/diagnostics.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/sheet_helpers.dart';
import '_lib/test_user.dart';

const String _circleName = 'Family';
const Duration _peerKeyPackageDeadline = Duration(seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // See scenario_01 for the sentinel-flag rationale.
  late ScenarioContext ctx;
  late String alicePubkeyHex;
  late String bobPubkeyHex;
  late String bobNpub;
  var didInitCtx = false;
  var didInitPreSeed = false;

  setUpAll(() async {
    ctx = await ScenarioHarness.bootstrap();
    didInitCtx = true;
    if (ctx.role == ScenarioRole.solo) {
      throw StateError(
        'scenario_05 requires --dart-define=HAVEN_E2E_ROLE=alice|bob',
      );
    }

    final aliceTmp = await TestUser.alice();
    alicePubkeyHex = aliceTmp.pubkeyHex;
    await aliceTmp.dispose();
    final bobTmp = await TestUser.bob();
    bobPubkeyHex = bobTmp.pubkeyHex;
    bobNpub = bobTmp.npub;
    await bobTmp.dispose();

    final seed = ctx.role == ScenarioRole.alice ? aliceSeed : bobSeed;
    await TestUser.preSeedIdentityAndSkipOnboarding(seed: seed);
    didInitPreSeed = true;
  });

  tearDownAll(() async {
    if (didInitPreSeed) {
      await TestUser.clearPreSeededIdentity();
    }
    if (didInitCtx) {
      await ctx.relay.dispose();
    }
  });

  testWidgets(
    'Alice (sole admin) leaves via the production UI; Bob observes her '
    'departure from his member list',
    (tester) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
          displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
          completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              onboardingControllerProvider.overrideWith(
                (ref) => OnboardingController(flags),
              ),
            ],
            child: const HavenApp(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(MapShell), findsOneWidget);

        // PHASE 1 — establish the circle (inlined invite/accept).
        switch (ctx.role) {
          case ScenarioRole.alice:
            await _aliceCreatesCircle(
              tester: tester,
              ctx: ctx,
              peerPubkeyHex: bobPubkeyHex,
              peerNpub: bobNpub,
            );
          case ScenarioRole.bob:
            await _bobAcceptsInvitation(
              tester: tester,
              ctx: ctx,
              selfPubkeyHex: bobPubkeyHex,
            );
          case ScenarioRole.solo:
            throw StateError('unreachable');
        }

        // PHASE 2 — admin leaves; non-admin observes eviction.
        switch (ctx.role) {
          case ScenarioRole.alice:
            await _aliceLeavesCircle(tester: tester);
          case ScenarioRole.bob:
            await _bobObservesAliceLeaving(
              tester: tester,
              ctx: ctx,
              peerPubkeyHex: alicePubkeyHex,
            );
          case ScenarioRole.solo:
            throw StateError('unreachable');
        }
      } on Object {
        // Flush observable state into logcat before re-throwing so
        // the CI failure artifact has enough context to triage
        // without re-running the scenario locally.
        await dumpScenarioState(
          tester: tester,
          ctx: ctx,
          label: 'scenario_05_failure',
        );
        rethrow;
      }
    },
    // 90s peer-KP + 90s gift-wrap + three relay round-trips for the
    // handoff + demote + leave commits + several rounds of Bob's
    // evolution-poll retries.
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

// =============================================================================
// PHASE 1 — circle establishment (inlined from scenario_02)
// =============================================================================

Future<void> _aliceCreatesCircle({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String peerPubkeyHex,
  required String peerNpub,
}) async {
  await waitForKeyPackage(
    relay: ctx.relay,
    authorPubkeyHex: peerPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );
  final giftWrapFuture = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: peerPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.byKey(WidgetKeys.circlesCreateCta),
  );
  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  await tester.pumpAndSettle();
  expect(find.byType(CreateCirclePage), findsOneWidget);
  await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), peerNpub);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(WidgetKeys.createCircleContinue));
  await tester.pumpAndSettle();
  expect(find.byType(NameCirclePage), findsOneWidget);
  await tester.enterText(find.byKey(WidgetKeys.circleNameInput), _circleName);
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  await tester.pumpAndSettle();
  expect(find.byType(MapShell), findsOneWidget);
  await giftWrapFuture;
}

Future<void> _bobAcceptsInvitation({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String selfPubkeyHex,
}) async {
  await waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: selfPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );
  // See scenario_02 for the pumpUntilFound/pumpUntilGone rationale —
  // MapShell's periodic timers stall pumpAndSettle indefinitely.
  await tester.tap(find.byKey(WidgetKeys.invitationsFloatingButton));
  await pumpUntilFound(
    tester,
    find.byType(InvitationsPage),
    timeout: const Duration(seconds: 15),
    description: 'InvitationsPage after tapping floating button',
  );
  for (var attempt = 0; attempt < 5; attempt++) {
    if (find.text('Accept').evaluate().isNotEmpty) break;
    await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
    await pumpUntilFound(
      tester,
      find.text('Accept'),
      timeout: const Duration(seconds: 10),
      description: 'Accept button after tapping refresh (attempt $attempt)',
    ).catchError((Object _) {});
  }
  expect(find.text('Accept'), findsOneWidget);
  await tester.tap(find.text('Accept'));
  await pumpUntilGone(
    tester,
    find.text('Accept'),
    description: 'Accept button disappearing after accept_invitation',
  );
  if (find.byType(InvitationsPage).evaluate().isNotEmpty) {
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        timeout: const Duration(seconds: 15),
        description: 'MapShell after navigating back from InvitationsPage',
      );
    }
  }
  expect(find.byType(MapShell), findsOneWidget);
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.textContaining(_circleName),
  );
  expect(find.textContaining(_circleName), findsAtLeastNWidgets(1));
}

// =============================================================================
// PHASE 2 — admin leaves + non-admin observation
// =============================================================================

/// Alice's flow: open the circle-details modal, tap Leave Circle, confirm
/// the dialog, assert the circle is gone from her list. From the UI's
/// perspective this is identical to scenario_04's non-admin Leave —
/// `LeavePlan::AdminHandoff` runs invisibly underneath, promoting Bob to
/// admin, self-demoting, and publishing the SelfRemove proposal.
Future<void> _aliceLeavesCircle({required WidgetTester tester}) async {
  final detailsButton = find.byTooltip('Circle details');
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        "After PHASE 1, Alice's selected-circle header with its "
        '"Circle details" info button must be visible in the bottom sheet.',
  );
  await tester.tap(detailsButton);
  await tester.pumpAndSettle();

  final leaveCta = find.byKey(WidgetKeys.leaveCircleCta);
  expect(leaveCta, findsOneWidget);
  await tester.ensureVisible(leaveCta);
  await tester.pumpAndSettle();
  await tester.tap(leaveCta);
  await tester.pumpAndSettle();

  final leaveConfirm = find.widgetWithText(TextButton, 'Leave');
  expect(leaveConfirm, findsOneWidget);
  await tester.tap(leaveConfirm);
  // FFI: planLeave (AdminHandoff) → proposeAdminHandoff → publish →
  // finalize → proposeSelfDemote → publish → finalize → proposeLeave →
  // publish → completeLeave. Three relay round-trips on Alice's side.
  await tester.pumpAndSettle();

  expect(find.byType(MapShell), findsOneWidget);
  // Best-effort re-expand: we don't use `expandCirclesSheetToMax`
  // because its termination condition is "target visible", and the
  // target here is *absent* by design after AdminHandoff succeeded.
  // `find.text` searches the whole tree, so even a partially-
  // collapsed sheet satisfies the assertion.
  final sheet = find.byType(DraggableScrollableSheet);
  if (sheet.evaluate().isNotEmpty) {
    await tester.dragFrom(tester.getCenter(sheet), const Offset(0, -600));
    await tester.pumpAndSettle();
  }
  expect(
    find.text(_circleName),
    findsNothing,
    reason:
        'After AdminHandoff completes, the circle named "$_circleName" '
        "must no longer appear in Alice's circle list.",
  );
}

/// Bob's flow: wait for Alice's three-commit AdminHandoff sequence to
/// land on the relay, then drive the production evolution poller +
/// member-fetch providers until Alice is no longer in his circle's
/// member list. The final UI-level assertion is that her membership
/// tile is gone — the downstream observable that proves the
/// protocol-level eviction landed.
///
/// The previous shape gated on "*at least one* kind-445 has appeared"
/// then ran a fixed-budget retry loop (8 × 5 s = 40 s). That budget
/// raced Alice's three relay round-trips: when PHASE 1 (invite/accept)
/// took longer than expected, Alice's Leave-Circle UI didn't even
/// start until well past the 40 s window from Bob's perspective and
/// Bob gave up before Alice published commits #2 and #3. Gating on
/// the count of commits instead of on a time budget makes the wait
/// proportional to the actual prerequisite landing on the wire.
Future<void> _bobObservesAliceLeaving({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String peerPubkeyHex,
}) async {
  // LeavePlan::AdminHandoff emits exactly three kind-445 commits in
  // sequence: AdminHandoff → SelfDemote → SelfRemove. Wait for all
  // three to land on the hermetic relay before asking Bob's MDK to
  // apply them. Four minutes is the slack budget — Alice's PHASE 1
  // takes ~2–3 min on a cold CI emulator and her actual leave flow
  // takes only seconds once it starts.
  const expectedCommits = 3;
  final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final allCommits = await ctx.relay.collectN(
    count: expectedCommits,
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      'since': cutoff,
      'limit': 50,
    },
    timeout: const Duration(minutes: 4),
  );
  expect(
    allCommits.length,
    greaterThanOrEqualTo(expectedCommits),
    reason:
        'Bob expected $expectedCommits kind-445 commit events on the '
        'relay within 4 min (AdminHandoff + SelfDemote + SelfRemove); '
        'only saw ${allCommits.length}. Either Alice never finished '
        'her three-step leave flow or the relay is dropping events.',
  );

  // All three commits are observable on the wire. Drive Bob's
  // evolution poller a few times to apply them locally; the loop is
  // short because the only remaining work is local MDK epoch
  // advancement once the events are already cached at this layer.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );
  final aliceTile = WidgetKeys.memberTile(peerPubkeyHex);
  var aliceGone = false;
  for (var attempt = 0; attempt < 8; attempt++) {
    container.invalidate(evolutionPollerProvider);
    await container.read(evolutionPollerProvider.future);
    container.invalidate(memberLocationsProvider);
    await container.read(memberLocationsProvider.future);
    await tester.pumpAndSettle();
    if (find.byKey(aliceTile).evaluate().isEmpty) {
      aliceGone = true;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    aliceGone,
    isTrue,
    reason:
        "Bob expected Alice's member tile (pubkey $peerPubkeyHex) to "
        'disappear after her AdminHandoff + SelfDemote + SelfRemove '
        'sequence committed. All three commits were observed on the '
        "relay but Bob's evolution poller failed to apply them or "
        'memberLocationsProvider is not invalidated after the '
        'membership change.',
  );
}
