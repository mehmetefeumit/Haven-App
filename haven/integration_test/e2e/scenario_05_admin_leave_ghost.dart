/// Scenario 05 — two-process: admin leave that triggers MDK's
/// admin-gate, producing the "ghost admin" condition. Bob's UI must
/// surface the production "Leaving…" badge on Alice's tile via the
/// production `pendingDepartureProvider` code path.
///
/// Background: see `docs/ADMIN_LEAVE_GHOST_BUG.md`. Haven's production
/// `LeavePlan::AdminHandoff` self-demotes the admin before publishing
/// SelfRemove, so the bug isn't reproducible from the normal Leave
/// Circle UI. The test invokes the dedicated test-only helper
/// `NostrCircleService.leaveCircleBypassHandoffForTest` (debug-only,
/// kReleaseMode-guarded) to publish the raw admin SelfRemove that
/// MDK's admin-gate ignores.
///
/// Acceptance hook (per plan §Verification per phase):
///   - Reverting the "Leaving…" badge code in `circle_member_tile.dart`
///     makes the badge assertion fail.
///   - Reverting the `pendingDepartureProvider` plumbing in
///     `location_sharing_service.dart` or `location_sharing_provider.dart`
///     makes the badge never appear.
///
/// Robust against the in-flight upstream fix: if MDK eventually drops
/// the admin-gate, the bypass-handoff helper still publishes a raw
/// SelfRemove. Whether the post-fix MDK applies it cleanly or still
/// ignores it, the test asserts only on observable artifacts that
/// Bob's UI surfaces — not on the internal MLS path taken.
library;

import 'package:flutter/material.dart' show DraggableScrollableSheet;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/evolution_poller_provider.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/services/nostr_circle_service.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/diagnostics.dart';
import '_lib/scenario_harness.dart';
import '_lib/test_user.dart';

const String _circleName = 'Family';
const Duration _ffiAwaitDeadline = Duration(seconds: 30);
const Duration _peerKeyPackageDeadline = Duration(seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ScenarioContext ctx;
  late String alicePubkeyHex;
  late String bobPubkeyHex;
  late String bobNpub;

  setUpAll(() async {
    ctx = await ScenarioHarness.bootstrap();
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
  });

  tearDownAll(() async {
    await TestUser.clearPreSeededIdentity();
    await ctx.relay.dispose();
  });

  testWidgets(
    'Alice (admin) publishes a bypass-handoff SelfRemove; Bob sees the '
    '"Leaving…" badge on her tile',
    (tester) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
          displayNameSet:
              prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
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

        // PHASE 2 — the ghost trigger + assertion.
        switch (ctx.role) {
          case ScenarioRole.alice:
            await _aliceTriggersGhost(tester: tester);
          case ScenarioRole.bob:
            await _bobObservesLeavingBadge(
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
    // 90 s peer-KP + 90 s gift-wrap + 60 s relay-side ghost SelfRemove
    // wait + a few rounds of evolution-poll retries + UI overhead.
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
  final sheet = find.byType(DraggableScrollableSheet);
  await tester.dragFrom(
    tester.getCenter(sheet),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  await tester.pumpAndSettle();
  expect(find.byType(CreateCirclePage), findsOneWidget);
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    peerNpub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle(_ffiAwaitDeadline);
  await tester.tap(find.byKey(WidgetKeys.createCircleContinue));
  await tester.pumpAndSettle();
  expect(find.byType(NameCirclePage), findsOneWidget);
  await tester.enterText(
    find.byKey(WidgetKeys.circleNameInput),
    _circleName,
  );
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  await tester.pumpAndSettle(_ffiAwaitDeadline);
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
  await tester.pumpAndSettle(_ffiAwaitDeadline);
  expect(find.byType(InvitationsPage), findsOneWidget);
  for (var attempt = 0; attempt < 5; attempt++) {
    if (find.text('Accept').evaluate().isNotEmpty) break;
    await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
    await tester.pumpAndSettle(_ffiAwaitDeadline);
  }
  expect(find.text('Accept'), findsOneWidget);
  await tester.tap(find.text('Accept'));
  await tester.pumpAndSettle(_ffiAwaitDeadline);
  if (find.byType(InvitationsPage).evaluate().isNotEmpty) {
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pumpAndSettle();
    }
  }
  expect(find.byType(MapShell), findsOneWidget);
  final sheet = find.byType(DraggableScrollableSheet);
  await tester.dragFrom(
    tester.getCenter(sheet),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();
  expect(find.textContaining(_circleName), findsAtLeastNWidgets(1));
}

// =============================================================================
// PHASE 2 — ghost trigger + assertion
// =============================================================================

/// Alice's flow: bypass the production LeavePlan ceremony and publish a
/// raw admin SelfRemove proposal that MDK's admin-gate will silently
/// reject on Bob's side, surfacing the bug the badge UI was added to
/// recover from.
Future<void> _aliceTriggersGhost({required WidgetTester tester}) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );

  // Resolve the circle's mlsGroupId via the production circles provider
  // (no test back door — this is the same `Circle` model the UI watches).
  final circles = await container.read(circlesProvider.future);
  final circle = circles.firstWhere(
    (c) => c.displayName == _circleName,
    orElse: () => throw StateError(
      'Circle "$_circleName" not found in circlesProvider after PHASE 1',
    ),
  );

  // The service exposes the production `leaveCircle` for normal use and
  // the test-only `leaveCircleBypassHandoffForTest` for this scenario.
  // The latter is @visibleForTesting + kReleaseMode-guarded so it
  // cannot be reached on shipped builds.
  final service = container.read(circleServiceProvider);
  if (service is! NostrCircleService) {
    throw StateError(
      'circleServiceProvider produced ${service.runtimeType}; '
      'scenario_05 requires the production NostrCircleService',
    );
  }
  await service.leaveCircleBypassHandoffForTest(
    mlsGroupId: circle.mlsGroupId,
  );
}

/// Bob's flow: drive the production evolution poll, then assert the
/// "Leaving…" badge appears on Alice's member tile.
Future<void> _bobObservesLeavingBadge({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String peerPubkeyHex,
}) async {
  // First, wait for Alice's bypass SelfRemove to actually land on the
  // relay. Without this, polling on Bob's side is pointless.
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

  // Force-fire the production fetch path. `pendingDepartureProvider`
  // is only written from `memberLocationsProvider` (see
  // `location_sharing_provider.dart:127-131`) — the evolution poller
  // logs the IgnoredProposal and moves on, leaving the badge state
  // unchanged. We fire BOTH providers per retry: the evolution poller
  // advances Bob's local MLS epoch so the next `fetchMemberLocations`
  // is consistent, then the member-locations fetch consumes the
  // IgnoredProposal and surfaces `pendingDepartureReason` to the
  // notifier the bottom sheet watches.
  final leavingBadge = WidgetKeys.memberLeavingBadge(peerPubkeyHex);
  var badgeFound = false;
  for (var attempt = 0; attempt < 6; attempt++) {
    container.invalidate(evolutionPollerProvider);
    await container.read(evolutionPollerProvider.future);
    container.invalidate(memberLocationsProvider);
    await container.read(memberLocationsProvider.future);
    await tester.pumpAndSettle(_ffiAwaitDeadline);
    if (find.byKey(leavingBadge).evaluate().isNotEmpty) {
      badgeFound = true;
      break;
    }
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    badgeFound,
    isTrue,
    reason: 'Bob expected to see the "Leaving…" badge on Alice\'s tile '
        '(pubkey $peerPubkeyHex) within the retry budget. Either '
        'pendingDepartureProvider did not receive the IgnoredProposal '
        'reason, or the CircleMemberTile no longer renders the badge.',
  );
}
