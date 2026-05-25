/// Scenario 02 — two-process: Alice creates a circle inviting Bob; Bob
/// accepts; both end with the same circle in their UI.
///
/// This is the first scenario that requires two emulators. The test
/// binary runs **twice**, once per role, selected via
/// `--dart-define=HAVEN_E2E_ROLE=alice|bob`. Both processes share the
/// same hermetic strfry relay, which is the coordination primitive —
/// Bob waits for the gift-wrap to land before tapping Accept, mirroring
/// production behavior exactly.
///
/// Acceptance hooks:
/// - Reverting `CircleManagerFfi.acceptInvitation` to no-op → Bob's
///   "circle appears in my list" assertion times out.
/// - Reverting the gift-wrap publish path → Alice's wait-for-gift-wrap
///   times out AND Bob's wait-for-gift-wrap times out.
/// - Reverting `signKeyPackageEvent` to no-op → Alice's wait-for-KP
///   times out before she can drive Create Circle.
library;

import 'package:flutter/widgets.dart' show DraggableScrollableSheet;
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
import '_lib/scenario_harness.dart';
import '_lib/test_user.dart';

/// Circle name the inviter (Alice) types into the form.
const String _circleName = 'Family';

/// Wall-clock budget for an FFI + relay round trip on a warm emulator.
const Duration _ffiAwaitDeadline = Duration(seconds: 30);

/// How long Bob waits for the gift-wrap to land before giving up. Longer
/// than the inviter-side wait because Bob's process may start a few
/// seconds before Alice's onboarding completes its KP publish.
const Duration _peerKeyPackageDeadline = Duration(seconds: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // See scenario_01 for the sentinel-flag rationale: defensive
  // tearDownAll prevents cascading LateInitializationErrors that
  // mask the real setUpAll failure in CI artifacts.
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
        'scenario_02 requires --dart-define=HAVEN_E2E_ROLE=alice|bob',
      );
    }

    // Both roles need Bob's deterministic pubkey/npub — Alice to enter
    // it into the member-search field, Bob to filter the gift-wrap.
    // (Alice's own pubkey is not needed: NIP-59 wraps with an
    // ephemeral outer key, so Bob can't filter by Alice's identity
    // pubkey anyway.) The temp TestUser is disposed once the strings
    // are captured.
    final bobTmp = await TestUser.bob();
    bobPubkeyHex = bobTmp.pubkeyHex;
    bobNpub = bobTmp.npub;
    await bobTmp.dispose();

    // Pre-seed this process's identity from its sentinel seed and skip
    // onboarding. Production identity-loading + KeyPackage-publisher
    // providers run exactly as in a real install.
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
    'Alice invites Bob; Bob accepts; both see the circle',
    (tester) async {
      // Mirror main()'s ProviderScope bootstrap: read the SharedPreferences
      // flags we just pre-seeded and override `onboardingControllerProvider`
      // with them. Without this override the controller's default factory
      // produces `OnboardingFlags.none` and the app routes to OnboardingShell
      // instead of MapShell. (Production does this in main.dart:46-56.)
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

      // Pre-seed dropped us straight into the map shell.
      expect(find.byType(MapShell), findsOneWidget);

      switch (ctx.role) {
        case ScenarioRole.alice:
          await _runAlice(
            tester: tester,
            ctx: ctx,
            peerPubkeyHex: bobPubkeyHex,
            peerNpub: bobNpub,
          );
        case ScenarioRole.bob:
          await _runBob(
            tester: tester,
            ctx: ctx,
            selfPubkeyHex: bobPubkeyHex,
          );
        case ScenarioRole.solo:
          // Already guarded in setUpAll.
          throw StateError('unreachable');
      }
    },
    // Scenario worst-case: 90 s peer-KP wait + 90 s gift-wrap wait + a
    // few FFI deadlines + cold-emulator overhead. Five minutes is the
    // floor with comfortable slack; the CI job timeout (50 min) and
    // ScenarioHarness.defaultTimeout (3 min, suitable for single-process
    // scenarios) are both insufficient for the worst case here.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Alice flow: wait for Bob's KP, drive Create Circle, await gift-wrap.
Future<void> _runAlice({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String peerPubkeyHex,
  required String peerNpub,
}) async {
  // Bob's KeyPackage must be on the relay before the member search can
  // resolve it. Bob's MapShell mount triggers the KP publish; on a warm
  // run this lands within a few seconds.
  await waitForKeyPackage(
    relay: ctx.relay,
    authorPubkeyHex: peerPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );

  // Open observation BEFORE the publish so we never miss the event.
  final giftWrapFuture = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: peerPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );

  // Expand the draggable bottom sheet to reveal the empty-state CTA.
  final sheetFinder = find.byType(DraggableScrollableSheet);
  expect(sheetFinder, findsOneWidget);
  await tester.dragFrom(
    tester.getCenter(sheetFinder),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  await tester.pumpAndSettle();

  // Member selection: enter Bob's npub, submit, await KP validation.
  expect(find.byType(CreateCirclePage), findsOneWidget);
  await tester.enterText(
    find.byKey(WidgetKeys.memberSearchInput),
    peerNpub,
  );
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle(_ffiAwaitDeadline);

  await tester.tap(find.byKey(WidgetKeys.createCircleContinue));
  await tester.pumpAndSettle();

  // Name + create.
  expect(find.byType(NameCirclePage), findsOneWidget);
  await tester.enterText(
    find.byKey(WidgetKeys.circleNameInput),
    _circleName,
  );
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  await tester.pumpAndSettle(_ffiAwaitDeadline);

  // Back on MapShell with the new circle.
  expect(find.byType(MapShell), findsOneWidget);
  expect(find.textContaining(_circleName), findsAtLeastNWidgets(1));

  // Confirm the gift-wrap actually landed on the relay.
  final giftWrap = await giftWrapFuture;
  expect(giftWrap.kind, equals(1059));
  final pTag = giftWrap.tag('p');
  expect(pTag, isNotNull);
  expect(pTag!.length, greaterThanOrEqualTo(2));
  expect(pTag[1].toLowerCase(), equals(peerPubkeyHex.toLowerCase()));
}

/// Bob flow: wait for the invitation, navigate to Invitations, accept,
/// assert the circle appears in the bottom-sheet list.
Future<void> _runBob({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String selfPubkeyHex,
}) async {
  // Gate Bob's UI actions on the actual gift-wrap landing — the
  // production invitation-poller will not see anything before then, so
  // tapping Accept first would either find nothing or race the fetch.
  await waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: selfPubkeyHex,
    timeout: _peerKeyPackageDeadline,
  );

  // Tap the floating invitations button on the map shell — InvitationsPage
  // auto-polls in initState, so the page mount itself triggers the fetch.
  await tester.tap(find.byKey(WidgetKeys.invitationsFloatingButton));
  await tester.pumpAndSettle(_ffiAwaitDeadline);
  expect(find.byType(InvitationsPage), findsOneWidget);

  // The card may take a beat after the page mounts before it appears.
  // Retry the refresh button a few times if the list is still loading.
  for (var attempt = 0; attempt < 5; attempt++) {
    if (find.text('Accept').evaluate().isNotEmpty) break;
    await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
    await tester.pumpAndSettle(_ffiAwaitDeadline);
  }
  expect(
    find.text('Accept'),
    findsOneWidget,
    reason:
        'Bob expected exactly one Accept button on the InvitationsPage '
        'after the gift-wrap landed on the relay.',
  );
  await tester.tap(find.text('Accept'));
  // acceptInvitation: FFI call + epoch advance + bottom-sheet refresh.
  await tester.pumpAndSettle(_ffiAwaitDeadline);

  // Some implementations pop back to the map shell after accept; others
  // leave the user on InvitationsPage with an empty state. Either way,
  // the circle should be visible somewhere — assert by navigating back
  // explicitly if needed, then look for the circle name.
  if (find.byType(InvitationsPage).evaluate().isNotEmpty) {
    final backButton = find.byTooltip('Back');
    if (backButton.evaluate().isNotEmpty) {
      await tester.tap(backButton);
      await tester.pumpAndSettle();
    }
  }
  expect(find.byType(MapShell), findsOneWidget);

  // Open the sheet so the circle list is visible.
  final sheetFinder = find.byType(DraggableScrollableSheet);
  expect(sheetFinder, findsOneWidget);
  await tester.dragFrom(
    tester.getCenter(sheetFinder),
    const Offset(0, -600),
  );
  await tester.pumpAndSettle();

  expect(
    find.textContaining(_circleName),
    findsAtLeastNWidgets(1),
    reason:
        'After acceptInvitation, the circle named "$_circleName" must '
        'appear in the circle list.',
  );
}
