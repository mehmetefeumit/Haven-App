/// Scenario 04 — two-process: Bob (non-admin) leaves the circle; Alice
/// observes his departure.
///
/// Setup (Phase 1): inlined from scenario_02 — Alice creates a circle
/// inviting Bob; Bob accepts. The duplication is deliberate to keep each
/// scenario self-contained.
///
/// Test phase: Bob navigates into the circle-details modal, taps Leave
/// Circle, confirms the dialog, and asserts the circle disappears from
/// his bottom sheet. Alice waits for Bob's SelfRemove kind-445 to land
/// on the hermetic strfry.
///
/// Acceptance hook: reverting `circle_service.leaveCircle` to no-op (or
/// dropping the `proposeLeave` publish in `nostr_circle_service.dart`)
/// makes Bob's assertion that the circle is gone fail AND Alice's
/// relay-side wait time out.
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
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
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
  late String bobPubkeyHex;
  late String bobNpub;
  var didInitCtx = false;
  var didInitPreSeed = false;

  setUpAll(() async {
    ctx = await ScenarioHarness.bootstrap();
    didInitCtx = true;
    if (ctx.role == ScenarioRole.solo) {
      throw StateError(
        'scenario_04 requires --dart-define=HAVEN_E2E_ROLE=alice|bob',
      );
    }

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

  testWidgets('Bob (non-admin) leaves the circle; Alice sees the SelfRemove on '
      'the relay', (tester) async {
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

    // ----------------------------------------------------------------
    // PHASE 1 — Establish the circle (inlined from scenario_02).
    // ----------------------------------------------------------------
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

    // ----------------------------------------------------------------
    // PHASE 2 — Per-role leave behaviour.
    // ----------------------------------------------------------------
    switch (ctx.role) {
      case ScenarioRole.alice:
        await _aliceWatchesBobLeave(tester: tester, ctx: ctx);
      case ScenarioRole.bob:
        await _bobLeavesCircle(tester: tester);
      case ScenarioRole.solo:
        throw StateError('unreachable');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
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
// PHASE 2 — leave + observation
// =============================================================================

/// Bob's flow: open the circle-details modal, tap Leave Circle, confirm
/// the dialog, assert the circle is gone from his list.
Future<void> _bobLeavesCircle({required WidgetTester tester}) async {
  // The "Circle details" IconButton sits on the selected-circle header
  // inside the bottom sheet. Tapping it opens a modal containing the
  // member list + Leave Circle CTA. Tooltip lookup is robust to icon
  // re-skinning; the production widget uses `LucideIcons.info` with the
  // tooltip 'Circle details' (circles_bottom_sheet.dart:910).
  final detailsButton = find.byTooltip('Circle details');
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        'After accepting the invitation, the selected-circle header '
        'with its "Circle details" info button must be visible in the '
        'bottom sheet.',
  );
  await tester.tap(detailsButton);
  await tester.pumpAndSettle();

  // Modal is now on top. Tap the Leave Circle CTA.
  final leaveCta = find.byKey(WidgetKeys.leaveCircleCta);
  expect(leaveCta, findsOneWidget);
  await tester.ensureVisible(leaveCta);
  await tester.pumpAndSettle();
  await tester.tap(leaveCta);
  await tester.pumpAndSettle();

  // Confirmation dialog appears. The Leave button is a `TextButton` with
  // text 'Leave' (vs the title "Leave Circle" which also contains
  // "Leave"). Use `find.widgetWithText(TextButton, 'Leave')` for an
  // unambiguous match.
  final leaveConfirm = find.widgetWithText(TextButton, 'Leave');
  expect(leaveConfirm, findsOneWidget);
  await tester.tap(leaveConfirm);
  // FFI: planLeave → proposeLeave → relay publish → completeLeave.
  await tester.pumpAndSettle();

  // Detail modal closes; we should be back on MapShell. The bottom
  // sheet's circle list no longer contains "Family".
  expect(find.byType(MapShell), findsOneWidget);
  // Bob's sheet may have collapsed during the modal lifecycle. Best-
  // effort re-expand: we don't use `expandCirclesSheetToMax` here
  // because its termination condition is "target finder visible" —
  // and the target here (`find.text(_circleName)`) is *absent* by
  // design after the leave succeeded. A single drag is sufficient
  // to bring the empty-state into view; the assertion below
  // tolerates either collapsed or expanded sheet because
  // `find.text` searches the entire tree, not just the viewport.
  final sheet = find.byType(DraggableScrollableSheet);
  if (sheet.evaluate().isNotEmpty) {
    await tester.dragFrom(tester.getCenter(sheet), const Offset(0, -600));
    await tester.pumpAndSettle();
  }
  expect(
    find.text(_circleName),
    findsNothing,
    reason:
        'After leaveCircle returns, the circle named "$_circleName" '
        'must no longer appear in the circle list.',
  );
}

/// Alice's flow: wait for Bob's SelfRemove kind-445 to land on the
/// hermetic strfry. The event proves Bob's `proposeLeave` + publish
/// reached the relay; if `leaveCircle` were reverted to a no-op, this
/// wait times out.
Future<void> _aliceWatchesBobLeave({
  required WidgetTester tester,
  required ScenarioContext ctx,
}) async {
  // Bob's SelfRemove rides as a kind-445 evolution event signed with an
  // ephemeral key. We cannot filter by `authors:` (ephemeral outer key)
  // — we wait on the kind alone. The hermetic relay has at most a few
  // kind-445 events (initial publishes from scenario setup might
  // produce some), so the firstWhere matcher accepts ANY new one
  // arriving after a stable cutoff.
  final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      'since': cutoff,
      'limit': 20,
    },
    timeout: const Duration(seconds: 90),
  );

  // Defensive — the assertion above is the load-bearing one. Pump the
  // UI a final time so any lingering rebuilds settle before teardown.
  await tester.pumpAndSettle();
}
