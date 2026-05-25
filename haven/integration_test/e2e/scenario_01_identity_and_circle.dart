/// Scenario 01 — single-instance: Alice creates her identity, then creates
/// a circle inviting a synthetic Bob.
///
/// This is the first Android E2E gate that exercises three production
/// code paths end-to-end:
///
/// 1. Onboarding identity generation (`IdentityNotifier.createIdentity` →
///    `NostrIdentityManager.createIdentity` FFI).
/// 2. Circle creation (`NostrCircleService.createCircle` →
///    `CircleManagerFfi.createCircle` FFI), producing the MLS group +
///    gift-wrapped Welcome.
/// 3. Welcome publication to the relay (the kind 1059 gift-wrap is sent
///    over the live WebSocket to strfry).
///
/// Acceptance: reverting any of the above to a no-op turns this scenario
/// red within the CI budget. See plan section "Verification per phase."
///
/// Multi-user scenarios (Bob accepts the invite, etc.) are Phase 2; here
/// Bob exists *only* as a published KeyPackage and a `#p` tag on the
/// resulting kind 1059. We do not assert on Bob's local state.
library;

import 'package:flutter/widgets.dart' show DraggableScrollableSheet;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/pages/onboarding/create_identity_screen.dart';
import 'package:haven/src/pages/onboarding/display_name_screen.dart';
import 'package:haven/src/pages/onboarding/ready_screen.dart';
import 'package:haven/src/pages/onboarding/value_props_screen.dart';
import 'package:haven/src/pages/onboarding/welcome_screen.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/scenario_harness.dart';
import '_lib/synthetic_user.dart';

/// Name the test types into the circle-name input. Held outside the test
/// body so post-creation assertions can reference the same value.
const String _circleName = 'Family';

/// Generous deadline for the slowest single step in this scenario — the
/// circle-creation FFI plus relay roundtrip dominates. Individual
/// `pumpAndSettle` calls retain Flutter's default deadline.
const Duration _ffiAwaitDeadline = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late ScenarioContext ctx;
  late SyntheticUser bob;

  setUpAll(() async {
    // Fresh onboarding state. The `OnboardingController.default_` reads
    // SharedPreferences on first build; setting empty mock values forces
    // a fresh flow even on a previously-used emulator.
    SharedPreferences.setMockInitialValues(<String, Object>{});

    // FFI + in-memory keyring + relay override + open TestRelay probe.
    ctx = await ScenarioHarness.bootstrap();

    // Publish Bob's KeyPackage to strfry. Alice's UI will fetch it during
    // member validation; without this the "Continue" button never enables.
    bob = await SyntheticUser.bob(ctx.relay);
  });

  tearDownAll(() async {
    await bob.dispose();
    await ctx.relay.dispose();
  });

  testWidgets(
    'Alice onboards, creates a circle inviting Bob, and the kind 1059 '
    'gift-wrap is observable on the relay',
    (tester) async {
      // -----------------------------------------------------------------
      // Start observing kind 1059 events addressed to Bob BEFORE Alice's
      // UI flow triggers the publish. Capturing the future early avoids a
      // race where the gift-wrap lands before our subscription is open.
      // -----------------------------------------------------------------
      final giftWrapFuture = waitForGiftWrap(
        relay: ctx.relay,
        recipientPubkeyHex: bob.pubkeyHex,
      );

      // -----------------------------------------------------------------
      // Launch the real Haven app. Default providers read SharedPreferences
      // (mocked empty) and the keyring (in-memory), so the app starts in
      // its onboarding state.
      // -----------------------------------------------------------------
      await tester.pumpWidget(const ProviderScope(child: HavenApp()));
      await tester.pumpAndSettle();

      // -----------------------------------------------------------------
      // Onboarding — five screens, each advanced via a stable WidgetKey.
      // -----------------------------------------------------------------

      // Step 1: Welcome → tap "Get Started".
      expect(find.byType(WelcomeScreen), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.welcomeCta));
      await tester.pumpAndSettle();

      // Step 2: ValueProps → tap "Continue".
      expect(find.byType(ValuePropsScreen), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.valuePropsCta));
      await tester.pumpAndSettle();

      // Step 3: CreateIdentity → tap "Create Identity".
      // This is the **first acceptance hook** — reverting
      // `IdentityNotifier.createIdentity` to no-op leaves us stuck here
      // because `identityProvider` never resolves, and the step machine
      // never advances past CreateIdentityScreen.
      expect(find.byType(CreateIdentityScreen), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.createIdentityCta));
      await tester.pumpAndSettle(_ffiAwaitDeadline);

      // Step 4: DisplayName → tap "Skip" (the test doesn't care about
      // local display names; the Skip path still flips the
      // `display_name_set` flag and advances).
      expect(find.byType(DisplayNameScreen), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.displayNameSkip));
      await tester.pumpAndSettle();

      // Step 5: Ready → tap "Enter Haven". AppRouter rebuilds into the
      // map shell once the completed flag flips.
      expect(find.byType(ReadyScreen), findsOneWidget);
      await tester.tap(find.byKey(WidgetKeys.readyCta));
      await tester.pumpAndSettle(_ffiAwaitDeadline);

      // -----------------------------------------------------------------
      // Map shell — first user with no circles. The empty-state CTA lives
      // inside the draggable circles bottom sheet, which initialises at
      // the 12% snap point (just the drag handle visible). We must
      // expand the sheet before the CTA enters the visible viewport;
      // `scrollUntilVisible` on the inner CustomScrollView does NOT
      // move the sheet's snap position.
      // -----------------------------------------------------------------
      expect(find.byType(MapShell), findsOneWidget);

      // Drag the sheet upward. A 600-pixel upward drag from the sheet's
      // current center reliably reaches the 85% snap on every standard
      // emulator viewport (Pixel 6 = 851 logical pixels tall).
      final sheetFinder = find.byType(DraggableScrollableSheet);
      expect(sheetFinder, findsOneWidget);
      await tester.dragFrom(
        tester.getCenter(sheetFinder),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();

      // Now tap the empty-state CTA by its stable widget key.
      final createCircleCta = find.byKey(WidgetKeys.circlesCreateCta);
      expect(createCircleCta, findsOneWidget);
      await tester.tap(createCircleCta);
      await tester.pumpAndSettle();

      // -----------------------------------------------------------------
      // CreateCirclePage — enter Bob's npub, wait for KeyPackage
      // validation, advance.
      // -----------------------------------------------------------------
      expect(find.byType(CreateCirclePage), findsOneWidget);
      await tester.enterText(
        find.byKey(WidgetKeys.memberSearchInput),
        bob.npub,
      );
      // The bar validates on TextInputAction.done as well as on Add-icon
      // tap; using the IME action is keyboard-only and robust.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      // KeyPackage fetch round-trips against strfry; allow up to the FFI
      // deadline for validation to complete.
      await tester.pumpAndSettle(_ffiAwaitDeadline);

      // Continue is gated on every selected member reaching `valid`.
      final continueBtn = find.byKey(WidgetKeys.createCircleContinue);
      expect(continueBtn, findsOneWidget);
      await tester.tap(continueBtn);
      await tester.pumpAndSettle();

      // -----------------------------------------------------------------
      // NameCirclePage — type the circle name, tap Create.
      // -----------------------------------------------------------------
      expect(find.byType(NameCirclePage), findsOneWidget);
      await tester.enterText(
        find.byKey(WidgetKeys.circleNameInput),
        _circleName,
      );
      await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));

      // This is the **second & third acceptance hook**:
      //   - Reverting `NostrCircleService.createCircle` makes the FFI
      //     call short-circuit before producing welcome events, so the
      //     publish never happens → `giftWrapFuture` times out.
      //   - Reverting the publish loop in `name_circle_page._createCircle`
      //     drops the gift-wrap before it reaches strfry → same timeout.
      await tester.pumpAndSettle(_ffiAwaitDeadline);

      // -----------------------------------------------------------------
      // Assertion 1 (UI): the circle is visible. After the navigator
      // pops twice we land on MapShell again with the new circle in the
      // bottom sheet. The SnackBar may still be visible too — either is
      // sufficient evidence that the create completed.
      // -----------------------------------------------------------------
      expect(find.byType(MapShell), findsOneWidget);
      // `find.text` matches either the SnackBar copy or the circle tile.
      expect(
        find.textContaining(_circleName),
        findsAtLeastNWidgets(1),
        reason:
            'After Create Circle returns, either the SnackBar '
            '("Circle \\"$_circleName\\" created!") or the new circle '
            'tile must be visible on the map shell',
      );

      // -----------------------------------------------------------------
      // Assertion 2 (relay): a kind 1059 gift-wrap addressed to Bob via
      // `#p` tag landed on strfry. This is the protocol-level guarantee
      // that the Welcome was actually published, independent of UI
      // state.
      // -----------------------------------------------------------------
      final giftWrap = await giftWrapFuture;
      expect(giftWrap.kind, equals(1059));
      final pTag = giftWrap.tag('p');
      expect(
        pTag,
        isNotNull,
        reason: 'NIP-59 gift wrap must carry a `p` tag with the recipient',
      );
      expect(
        pTag!.length,
        greaterThanOrEqualTo(2),
        reason: 'p tag must be ["p", "<pubkey>", ...]',
      );
      expect(
        pTag[1].toLowerCase(),
        equals(bob.pubkeyHex.toLowerCase()),
        reason: 'recipient `p` tag must match Bob',
      );

      // Defensive: outer pubkey on a gift-wrap is ephemeral (per NIP-59
      // / Marmot security rule 2), so it must differ from Bob's identity
      // pubkey. We don't have Alice's pubkey conveniently, but we can
      // assert the outer pubkey isn't Bob's (a regression that wired the
      // recipient as the outer key would imply a serious crypto leak).
      expect(
        giftWrap.pubkey.toLowerCase(),
        isNot(equals(bob.pubkeyHex.toLowerCase())),
      );

      // Use `print` (not debugPrint): debugPrint is silenced in release
      // builds by `lib/main.dart`'s `kReleaseMode` guard, but this success
      // line should surface in CI logs even if the test binary is built
      // in profile mode. `flutter test integration_test/` runs in profile
      // mode by default — keeping `print` ensures the line is captured.
      // ignore: avoid_print
      print(
        '[scenario_01] OK: circle "$_circleName" created, gift-wrap '
        '${giftWrap.id} observed on strfry',
      );
    },
    timeout: ScenarioHarness.defaultTimeout,
  );
}
