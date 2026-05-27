/// Scenario 03 — two-process: Alice and Bob share location.
///
/// Builds on the same coordinated two-AVD harness as scenario_02:
/// pre-seeded deterministic identities, role-branched per process,
/// hermetic strfry for synchronization.
///
/// Flow:
///   1. Both roles drive the scenario_02 invite/accept UI flow so the
///      circle is established. The circle-setup duplication is
///      deliberate — keeping each scenario self-contained makes
///      individual failures easier to triage.
///   2. The production `locationPublisherProvider` fires automatically
///      after circle creation / acceptance (see map_shell.dart:607 and
///      invitation_card.dart's accept handler). Both sides therefore
///      publish their location once the previous step settles.
///   3. Each role waits for the peer's kind-445 event on the relay,
///      then forces a `memberLocationsProvider` refresh and asserts the
///      peer's marker is visible on the map via
///      `WidgetKeys.memberMarker(peerPubkeyHex)`.
///
/// Acceptance hooks:
///   - Reverting `CircleManagerFfi.encryptLocation` to no-op → the
///     publishing path produces no kind-445 events; both roles' relay
///     waits time out.
///   - Reverting `CircleManagerFfi.decryptLocation` to no-op → events
///     arrive on the relay but the production `memberLocationsProvider`
///     produces an empty list; the marker assertion fails.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/invitations/invitations_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/fake_location_service.dart';
import '_lib/scenario_harness.dart';
import '_lib/sheet_helpers.dart';
import '_lib/test_user.dart';

const String _circleName = 'Family';
const Duration _ffiAwaitDeadline = Duration(seconds: 30);
const Duration _peerKeyPackageDeadline = Duration(seconds: 90);
const Duration _locationEventDeadline = Duration(seconds: 60);

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
        'scenario_03 requires --dart-define=HAVEN_E2E_ROLE=alice|bob',
      );
    }

    // Both roles need both pubkeys: each asserts the OTHER's marker on
    // their map, and the npub is needed by Alice for the member search.
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
    'Alice and Bob each publish location; each sees the other on the map',
    (tester) async {
      // ----------------------------------------------------------------
      // Pump HavenApp with two ProviderScope overrides:
      //   1. onboardingControllerProvider — mirrors main()'s bootstrap so
      //      the pre-seeded flags route to MapShell (not OnboardingShell).
      //   2. locationServiceProvider — fake returning sentinel coords.
      //      Without this override, locationPublisherProvider would call
      //      the production geolocator which has no permission in CI and
      //      no GPS fix on a headless emulator.
      // ----------------------------------------------------------------
      final prefs = await SharedPreferences.getInstance();
      final flags = OnboardingFlags(
        introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
        displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
        completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
      );
      final fakeLocation = ctx.role == ScenarioRole.alice
          ? FakeLocationService(
              latitude: aliceFakeLatitude,
              longitude: aliceFakeLongitude,
            )
          : FakeLocationService(
              latitude: bobFakeLatitude,
              longitude: bobFakeLongitude,
            );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(flags),
            ),
            locationServiceProvider.overrideWithValue(fakeLocation),
          ],
          child: const HavenApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MapShell), findsOneWidget);

      // ----------------------------------------------------------------
      // PHASE 1 — Establish the circle via the production UI flow.
      // Duplicates scenario_02's body intentionally; both scenarios stay
      // self-contained.
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
      // PHASE 2 — Force a location publish from THIS role.
      //
      // The production app already fires locationPublisherProvider after
      // circle creation (map_shell.dart) and after invitation accept
      // (invitation_card.dart). Those auto-publishes might land before
      // the peer's MLS group is fully merged (epoch race). Re-firing
      // explicitly here, after both sides have settled into MapShell,
      // gives the receiver a fresh kind-445 event AFTER its
      // acceptInvitation completed.
      // ----------------------------------------------------------------
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        // `listen: false` avoids registering a never-cleaned dependency
        // listener on the test's ProviderContainer; the container is
        // disposed at test teardown regardless, but the explicit form
        // is the idiomatic test pattern.
        listen: false,
      )..invalidate(locationPublisherProvider);
      final publishedCount = await container.read(
        locationPublisherProvider.future,
      );
      expect(
        publishedCount,
        greaterThanOrEqualTo(1),
        reason:
            'locationPublisherProvider must have published to at '
            'least one accepted circle; got 0 which means encryptLocation '
            'either no-op-ed or no accepted circles exist.',
      );

      // ----------------------------------------------------------------
      // PHASE 3 — Wait for the peer's kind-445 to land on the relay.
      // Independent of UI, this catches an encryptLocation no-op even if
      // the UI assertion would otherwise pass vacuously.
      // ----------------------------------------------------------------
      final peerPubkeyHex = ctx.role == ScenarioRole.alice
          ? bobPubkeyHex
          : alicePubkeyHex;
      // The relay events use the EPHEMERAL outer pubkey, not the sender
      // identity. We can't filter by `authors:[peerHex]`. Instead we wait
      // for ANY kind-445 to appear on the circle's relay (there's only
      // one circle and two publishers — the count rises as events land).
      // Use the circle's nostr_group_id as the `#h` tag filter. We don't
      // know nostr_group_id from the test, so we filter by kind alone
      // and accept any event (hermetic relay, no noise).
      var peerEventSeen = false;
      final deadline = DateTime.now().add(_locationEventDeadline);
      while (DateTime.now().isBefore(deadline)) {
        try {
          await ctx.relay.firstWhere(
            filter: const <String, dynamic>{
              'kinds': <int>[445],
              'limit': 50,
            },
            timeout: const Duration(seconds: 10),
          );
          // We've seen *a* kind-445. We don't have a way to tell from
          // the outer event whether it's the peer's or our own (both use
          // ephemeral keys). Accept the first one and proceed — the
          // PHASE 4 marker assertion will fail if we never decrypt the
          // peer's content into the member-locations list.
          peerEventSeen = true;
          break;
        } on TimeoutException {
          // Try again until the overall deadline.
        }
      }
      expect(
        peerEventSeen,
        isTrue,
        reason:
            'No kind-445 events observed on the relay within '
            '${_locationEventDeadline.inSeconds}s — encryptLocation may '
            'have been reverted to a no-op.',
      );

      // ----------------------------------------------------------------
      // PHASE 4 — Wait for the production memberLocationsProvider to
      // surface the peer's location. The provider polls the relay and
      // calls decryptLocation on every event; the peer's pubkey ends up
      // in the list once decryption succeeds.
      //
      // We retry the invalidate + read cycle because MLS epoch races
      // can briefly produce empty results: if Bob's epoch hasn't caught
      // up to Alice's commit yet, decryptLocation returns null on the
      // first pass and only succeeds after the evolution-poller advances
      // his local state.
      // ----------------------------------------------------------------
      var markerFound = false;
      final markerKey = WidgetKeys.memberMarker(peerPubkeyHex);
      for (var attempt = 0; attempt < 6; attempt++) {
        container.invalidate(memberLocationsProvider);
        await container.read(memberLocationsProvider.future);
        await tester.pumpAndSettle(_ffiAwaitDeadline);
        if (find.byKey(markerKey).evaluate().isNotEmpty) {
          markerFound = true;
          break;
        }
        // Brief breath before retrying so the evolution poller has time
        // to advance the local MLS epoch on its own schedule.
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      expect(
        markerFound,
        isTrue,
        reason:
            'Peer marker for pubkey $peerPubkeyHex did not appear on '
            'the map within the retry budget. Either decryptLocation '
            'returned null (FFI regression) or the MLS epoch race did '
            'not converge.',
      );
    },
    // Worst case: 90 s peer-KP wait + 90 s gift-wrap wait + 60 s
    // location-event wait + decrypt retries. Eight minutes is the floor
    // with comfortable slack.
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// Alice's leg of the invite/accept flow — identical to scenario_02
/// _runAlice but inlined here so scenario_03 stays self-contained.
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

  // See scenario_02 for the rationale behind the retry-aware helper.
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.byKey(WidgetKeys.circlesCreateCta),
  );

  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  await tester.pumpAndSettle();

  expect(find.byType(CreateCirclePage), findsOneWidget);
  await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), peerNpub);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle(_ffiAwaitDeadline);

  await tester.tap(find.byKey(WidgetKeys.createCircleContinue));
  await tester.pumpAndSettle();

  expect(find.byType(NameCirclePage), findsOneWidget);
  await tester.enterText(find.byKey(WidgetKeys.circleNameInput), _circleName);
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  await tester.pumpAndSettle(_ffiAwaitDeadline);

  expect(find.byType(MapShell), findsOneWidget);
  expect(find.textContaining(_circleName), findsAtLeastNWidgets(1));

  // Confirm the gift-wrap actually landed; without it Bob's accept will
  // time out and the location publish never happens.
  await giftWrapFuture;
}

/// Bob's leg of the invite/accept flow — identical to scenario_02 _runBob
/// but inlined here for self-containment.
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

  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.textContaining(_circleName),
  );

  expect(find.textContaining(_circleName), findsAtLeastNWidgets(1));
}
