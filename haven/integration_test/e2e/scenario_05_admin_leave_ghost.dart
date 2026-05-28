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
  await tester.tap(find.byKey(WidgetKeys.invitationsFloatingButton));
  await tester.pumpAndSettle();
  expect(find.byType(InvitationsPage), findsOneWidget);
  for (var attempt = 0; attempt < 5; attempt++) {
    if (find.text('Accept').evaluate().isNotEmpty) break;
    await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
    await tester.pumpAndSettle();
  }
  expect(find.text('Accept'), findsOneWidget);
  await tester.tap(find.text('Accept'));
  await tester.pumpAndSettle();
  if (find.byType(InvitationsPage).evaluate().isNotEmpty) {
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pumpAndSettle();
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

/// Bob's flow: wait for the kind-445 commit stream from Alice's three-step
/// leave, then drive the production evolution poller + member-fetch
/// providers until Alice is no longer in his circle's member list. The
/// final UI-level assertion is that her membership tile is gone — the
/// downstream observable that proves the protocol-level eviction landed.
Future<void> _bobObservesAliceLeaving({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String peerPubkeyHex,
}) async {
  // Wait for at least one of Alice's commit events to hit the relay.
  // Three are emitted (handoff, demote, leave); the firstWhere only
  // needs one to know Alice's flow has started.
  final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      'since': cutoff,
      'limit': 20,
    },
    timeout: const Duration(seconds: 90),
  );

  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );

  // Drive the evolution poller + member-fetch loop until Alice's tile
  // disappears. Each iteration advances Bob's local MLS state by one
  // commit; three iterations should be enough but we allow headroom.
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
        'disappear after her AdminHandoff + selfDemote + SelfRemove '
        'sequence committed. If the tile is still present, either '
        'LeavePlan::AdminHandoff did not emit all three commits, the '
        'evolution poller failed to apply them, or memberLocationsProvider '
        'is not invalidated after the membership change.',
  );
}
