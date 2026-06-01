/// Consolidated end-to-end test — three users, one flow.
///
/// This file replaces the five per-flow scenario files (identity & circle
/// creation, invitation accept, location sharing, non-admin leave, admin
/// leave with handoff) with a single three-process integration test that
/// drives Alice, Bob, and Carol through the complete Haven lifecycle:
///
///   PHASE 1 — Identity-loading + MapShell mount.
///       All three processes pre-seed deterministic ephemeral identities
///       (sentinel seeds 0x01 / 0x02 / 0x03) into `flutter_secure_storage`,
///       skip onboarding via the same SharedPreferences flags the production
///       app writes after onboarding completes, and pump `HavenApp` to land
///       on `MapShell`. The identity-loading code path under test is
///       *exactly* what runs in production once a user has finished the
///       onboarding flow. The interactive UI onboarding itself (typing,
///       skip taps, FFI key generation) is exercised in isolation by
///       `smoke_test.dart` so its UI-skin churn does not destabilize this
///       broader flow.
///
///   PHASE 2 — Three-member circle creation + multi-recipient Welcome.
///       Alice invites BOTH Bob and Carol in a single `Create Circle`
///       flow (the production UI's `CreateCirclePage` supports an
///       unbounded list of selected members). The MLS group is born with
///       three members; two kind-1059 gift-wraps are published in the
///       same code path. Bob and Carol each navigate to InvitationsPage
///       and tap Accept independently. The production UI does not (yet)
///       expose a "add member to existing circle" affordance — when
///       that lands, this scenario should grow a sub-phase that exercises
///       the post-creation `addMembers` FFI through the new UI surface.
///
///   PHASE 3 — Three-way location sharing.
///       Each role explicitly fires `locationPublisherProvider` after
///       Phase 2 settles. Each role then asserts that the production
///       `memberLocationsProvider` surfaces markers for the *other two*
///       members (driving `memberLocationsProvider` invalidation + read
///       with bounded retries to absorb the MLS epoch race the existing
///       scenarios already navigate). This is the regression coverage
///       for `encryptLocation`, `decryptLocation`, and the
///       memberLocations → `MemberMarker` rendering path.
///
///   PHASE 4 — Admin leave with `LeavePlan::AdminHandoff`.
///       Alice (sole admin) opens Circle Details, taps Leave Circle,
///       confirms. Her three-commit MLS sequence (AdminHandoff →
///       SelfDemote → SelfRemove) lands on the hermetic strfry. Bob and
///       Carol observe via `TestRelay.collectN`, then drive their
///       evolution poller + member-locations provider until Alice is no
///       longer in the member list. After Phase 4 settles, exactly one
///       of Bob/Carol holds `isAdmin == true` (the lex-smallest non-self
///       member of the original group, per
///       `haven-core/src/circle/leave.rs::select_successor`). Each role
///       reads its own `isAdmin` at runtime — the test does not hard-
///       code which becomes admin because that depends on secp256k1
///       derivation of the sentinel seeds and could change if the seed
///       constants ever shift.
///
///   PHASE 5 — Non-admin leave (residual 2-member group).
///       Whichever of Bob/Carol came out of Phase 4 as a non-admin opens
///       the Leave Circle flow. The new admin observes the kind-445
///       SelfRemove on the relay, drives their poller, and asserts the
///       leaver's member tile is gone. The test ends with the admin
///       holding a 1-member group — `LeavePlan::Abandon`'s sole-
///       remaining-member cleanup is NOT exercised here (it would
///       require the admin to then trigger their own Leave, which is
///       out of scope for this combined flow). Add a follow-up that
///       drives the residual admin through one more Leave when
///       Abandon-path coverage becomes useful.
///
/// ## Coordination model
///
/// All cross-process synchronization is via observable Nostr events on
/// the hermetic strfry relay. There is no filesystem, environment, or
/// other side channel — this is the same model production Haven uses
/// (Bob's instance only learns of Alice's invitation when a gift-wrap
/// shows up on his inbox relay). The hermetic relay means seed pubkeys
/// can never reach a production relay even if the override mechanism
/// were bypassed; combined with the loopback-only URL guard in
/// `TestUser.bootstrapProcess`, this is privacy-enforced structurally.
///
/// ## Acceptance hooks
///
/// Reverting any of the following to a no-op turns this scenario red:
///   - `IdentityNotifier.createIdentity` (Phase 1 — MapShell never mounts).
///   - `NostrCircleService.createCircle` (Phase 2 — gift-wrap wait times out).
///   - `signKeyPackageEvent` (Phase 2 — Alice's KP wait times out).
///   - `CircleManagerFfi.acceptInvitation` (Phase 2 — Bob/Carol circle
///     never materializes).
///   - `encryptLocation` (Phase 3 — kind-445 wait times out).
///   - `decryptLocation` (Phase 3 — member marker never appears).
///   - `LeavePlan::AdminHandoff` to skip `proposeAdminHandoff` or
///     `proposeSelfDemote` (Phase 4 — Alice's leave fails at MDK's
///     admin-gate).
///   - `LeavePlan::NonAdmin` (Phase 5 — non-admin's leave hangs).
///
/// ## Privacy notes
///
/// - All keys are deterministic ephemeral sentinels (0x01 / 0x02 / 0x03)
///   visible only to the hermetic relay. The loopback guard in
///   `TestUser.bootstrapProcess` rejects any non-localhost relay URL.
/// - The diagnostic dumper logs `circle.members.length` and
///   `memberLocations.count` — both are public-by-design Haven metadata
///   (not MLS group IDs or secret material).
/// - The fake location coordinates are sentinel decimals far from any
///   populated area and unmistakable in logcat.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart' show TextButton;
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
import 'package:haven/src/services/circle_service.dart' show Circle;
import 'package:haven/src/services/location_service.dart' show LocationService;
import 'package:haven/src/test_keys.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '_lib/coordination.dart';
import '_lib/diagnostics.dart';
import '_lib/fake_location_service.dart';
import '_lib/pump_helpers.dart';
import '_lib/scenario_harness.dart';
import '_lib/sheet_helpers.dart';
import '_lib/test_relay.dart' show TestRelayEvent;
import '_lib/test_user.dart';

// =============================================================================
// Constants
// =============================================================================

/// Circle name Alice types into the form. Used as a `find.text(...)`
/// anchor across phases.
const String _circleName = 'Family';

/// Outer deadline on relay-level waits for a peer's KeyPackage to land.
/// Generous because cold-AVD KP publication races onboarding settle.
const Duration _peerKeyPackageDeadline = Duration(seconds: 90);

/// Outer deadline on relay-level waits for a kind-1059 gift-wrap.
const Duration _giftWrapDeadline = Duration(seconds: 90);

/// Outer deadline on relay-level waits for a single kind-445 location
/// event. Production publishes every 30 s from `_receiveTimer`; we
/// invalidate `locationPublisherProvider` explicitly so the deadline
/// covers FFI work, not the production polling cadence.
const Duration _locationEventDeadline = Duration(seconds: 60);

/// Outer deadline on the `LeavePlan::AdminHandoff` three-commit
/// collection (AdminHandoff → SelfDemote → SelfRemove).
const Duration _adminHandoffDeadline = Duration(minutes: 4);

/// Outer deadline on a single kind-445 commit after a non-admin leave.
const Duration _nonAdminLeaveDeadline = Duration(seconds: 90);

/// Overall test budget. Worst case across all phases is about 15 min on
/// a cold CI emulator; 25 min leaves comfortable slack. The outer CI
/// job timeout (typically 50 min) bounds the absolute upper limit.
const Duration _outerTestTimeout = Duration(minutes: 25);

// =============================================================================
// Entry point
// =============================================================================

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // `late` keeps the test body ergonomic; the `_didInit*` sentinels make
  // `tearDownAll` safe against a partial `setUpAll` failure. Without
  // them, a `LateInitializationError` in `tearDownAll` cascades onto
  // the original `setUpAll` failure and masks the real cause in the
  // CI artifact.
  late ScenarioContext ctx;
  // Alice's pubkey is the only Alice-credential we keep — Bob and Carol
  // need it for their member-tile assertions after PHASE 4. We do NOT
  // need Alice's npub: Alice's identity is pre-seeded into this role's
  // process, and the other roles never type Alice's npub anywhere.
  late String alicePubkeyHex;
  // Bob and Carol need both fields: pubkey for membership assertions,
  // npub for Alice to type into the CreateCirclePage member-search
  // field in PHASE 2.
  late String bobPubkeyHex;
  late String bobNpub;
  late String carolPubkeyHex;
  late String carolNpub;
  var didInitCtx = false;
  var didInitPreSeed = false;

  setUpAll(() async {
    // ScenarioHarness initializes the Rust bridge, installs the in-
    // memory keyring, applies the loopback relay override, and opens
    // a TestRelay probe socket to strfry.
    ctx = await ScenarioHarness.bootstrap();
    didInitCtx = true;

    if (ctx.role == ScenarioRole.solo) {
      throw StateError(
        'e2e_combined requires '
        '--dart-define=HAVEN_E2E_ROLE=alice|bob|carol',
      );
    }

    // Every role needs every pubkey + npub:
    //   - Alice enters Bob's + Carol's npubs into the member-search field.
    //   - Bob and Carol assert Alice's tile disappears after she leaves
    //     (they need her pubkey for `WidgetKeys.memberTile(...)`).
    //   - The non-admin's pubkey is needed by the residual admin in
    //     Phase 5 to assert the right tile disappeared.
    //
    // We deliberately use `derivePubkeyAndNpub` instead of the heavier
    // `TestUser.bootstrap` here. The latter would construct three
    // `CircleManagerFfi` instances — each opening a SQLCipher connection
    // and an MdkManager — solely to read public-identity strings. FRB
    // opaque handles only drop when Dart GC runs (non-deterministic),
    // so those instances would linger as zombie connections for the
    // remainder of the process. The lightweight helper just runs
    // `NostrIdentityManager.loadFromBytes` and reads the public fields,
    // which is the exact same pubkey-derivation path the production
    // identity-loading code exercises.
    final aliceIdent = await TestUser.derivePubkeyAndNpub(aliceSeed);
    alicePubkeyHex = aliceIdent.pubkeyHex;
    final bobIdent = await TestUser.derivePubkeyAndNpub(bobSeed);
    bobPubkeyHex = bobIdent.pubkeyHex;
    bobNpub = bobIdent.npub;
    final carolIdent = await TestUser.derivePubkeyAndNpub(carolSeed);
    carolPubkeyHex = carolIdent.pubkeyHex;
    carolNpub = carolIdent.npub;

    // Pre-seed THIS process's identity from its sentinel seed and skip
    // onboarding. The production identity-loading + KeyPackagePublisher
    // providers run exactly as in a real install — the only difference
    // from real onboarding is the seed source (sentinel vs. RNG).
    final seed = switch (ctx.role) {
      ScenarioRole.alice => aliceSeed,
      ScenarioRole.bob => bobSeed,
      ScenarioRole.carol => carolSeed,
      // `solo` was already rejected; the switch must remain exhaustive
      // so future enum additions surface a compile error here.
      ScenarioRole.solo =>
        throw UnimplementedError('e2e_combined does not support solo'),
    };
    await TestUser.preSeedIdentityAndSkipOnboarding(seed: seed);
    didInitPreSeed = true;

    debugPrint(
      '[e2e_combined:setUpAll] role=${ctx.role.name} '
      'alice=${_redactPubkey(alicePubkeyHex)} '
      'bob=${_redactPubkey(bobPubkeyHex)} '
      'carol=${_redactPubkey(carolPubkeyHex)}',
    );
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
    'three users: identity → 3-member invite → 3-way location → '
    'admin leave (handoff) → non-admin leave',
    (tester) async {
      try {
        // -----------------------------------------------------------
        // PHASE 1 — pump HavenApp with role's identity pre-seeded and
        // the production geolocator replaced by a deterministic fake.
        // -----------------------------------------------------------
        final prefs = await SharedPreferences.getInstance();
        final flags = OnboardingFlags(
          introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
          displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
          completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
        );
        final fakeLocation = _fakeLocationFor(ctx.role);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Mirrors production main()'s bootstrap: feed the pre-
              // seeded flags so AppRouter routes straight to MapShell
              // instead of starting an onboarding flow. Without this
              // override the default factory produces
              // `OnboardingFlags.none` and the app routes to
              // OnboardingShell despite the SharedPreferences keys
              // being already set.
              onboardingControllerProvider.overrideWith(
                (ref) => OnboardingController(flags),
              ),
              // Without the fake, `locationPublisherProvider` calls the
              // real Geolocator which has no permission in CI and no
              // GPS fix on a headless emulator. The fake satisfies the
              // production interface end-to-end (every method returns
              // a realistic default) so the publish path runs linearly
              // with no permission-denied early exits.
              locationServiceProvider.overrideWithValue(fakeLocation),
            ],
            child: const HavenApp(),
          ),
        );
        // Wait for MapShell via pumpUntilFound, NOT pumpAndSettle —
        // MapShell's initState installs three periodic timers
        // (evolution 60 s, location-receive 30 s, foreground heartbeat)
        // that fire before pumpAndSettle ever sees an empty frame
        // queue. The test would otherwise silently block here for the
        // full outer timeout. See pump_helpers.dart for the canonical
        // rationale.
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          description: 'MapShell after pumpWidget',
        );

        // -----------------------------------------------------------
        // PHASE 2 — establish the three-member circle.
        // -----------------------------------------------------------
        switch (ctx.role) {
          case ScenarioRole.alice:
            await _aliceCreatesThreeMemberCircle(
              tester: tester,
              ctx: ctx,
              bobPubkeyHex: bobPubkeyHex,
              bobNpub: bobNpub,
              carolPubkeyHex: carolPubkeyHex,
              carolNpub: carolNpub,
            );
          case ScenarioRole.bob:
            await _acceptInvitation(
              tester: tester,
              ctx: ctx,
              selfPubkeyHex: bobPubkeyHex,
              roleLabel: 'bob',
              expectedMemberPubkeys: <String>[
                alicePubkeyHex,
                bobPubkeyHex,
                carolPubkeyHex,
              ],
            );
          case ScenarioRole.carol:
            await _acceptInvitation(
              tester: tester,
              ctx: ctx,
              selfPubkeyHex: carolPubkeyHex,
              roleLabel: 'carol',
              expectedMemberPubkeys: <String>[
                alicePubkeyHex,
                bobPubkeyHex,
                carolPubkeyHex,
              ],
            );
          case ScenarioRole.solo:
            throw UnimplementedError(
              'e2e_combined does not support ScenarioRole.solo; '
              'the setUpAll guard should have rejected it already',
            );
        }

        // -----------------------------------------------------------
        // PHASE 3 — three-way location sharing.
        //
        // Every role asserts the OTHER two members' markers appear on
        // its map. Each role's own marker is intentionally not
        // asserted (production renders peer markers only; self-marker
        // would require a separate `self_marker` assertion that is
        // out of scope for this combined test).
        // -----------------------------------------------------------
        final selfPubkeyHex = _selfPubkeyHexFor(
          ctx.role,
          alice: alicePubkeyHex,
          bob: bobPubkeyHex,
          carol: carolPubkeyHex,
        );
        final peerPubkeyHexes = <String>[
          alicePubkeyHex,
          bobPubkeyHex,
          carolPubkeyHex,
        ].where((pk) => pk != selfPubkeyHex).toList(growable: false);

        await _publishLocationAndObservePeers(
          tester: tester,
          peerPubkeyHexes: peerPubkeyHexes,
          ctx: ctx,
        );

        // -----------------------------------------------------------
        // PHASE 4 — Alice (sole admin) leaves; Bob and Carol observe.
        // -----------------------------------------------------------
        switch (ctx.role) {
          case ScenarioRole.alice:
            await _aliceLeavesCircle(tester: tester);
            debugPrint('[e2e_combined:alice] PHASE 4 complete; exiting.');
            // Alice's role ends here. The test body returns; the outer
            // timeout still bounds the await above, but no further
            // assertions run on Alice's side.
            return;
          case ScenarioRole.bob:
          case ScenarioRole.carol:
            await _observeAliceDeparture(
              tester: tester,
              ctx: ctx,
              alicePubkeyHex: alicePubkeyHex,
            );
          case ScenarioRole.solo:
            throw UnimplementedError(
              'e2e_combined does not support ScenarioRole.solo; '
              'the setUpAll guard should have rejected it already',
            );
        }

        // -----------------------------------------------------------
        // PHASE 5 — non-admin leaves; new admin observes.
        //
        // After Phase 4, exactly one of Bob/Carol holds isAdmin=true
        // (the lex-smallest of the two pubkeys, per `select_successor`
        // in haven-core/src/circle/leave.rs). Each role reads its own
        // isAdmin at runtime: the admin watches, the non-admin leaves.
        // -----------------------------------------------------------
        final selfIsAdmin = await _selfIsAdmin(
          tester: tester,
          selfPubkeyHex: selfPubkeyHex,
        );
        debugPrint(
          '[e2e_combined:${ctx.role.name}] post-handoff selfIsAdmin='
          '$selfIsAdmin',
        );
        if (selfIsAdmin) {
          // Self is the new admin. The OTHER non-admin is going to leave.
          final otherPubkeyHex = ctx.role == ScenarioRole.bob
              ? carolPubkeyHex
              : bobPubkeyHex;
          await _observeNonAdminLeave(
            tester: tester,
            ctx: ctx,
            otherPubkeyHex: otherPubkeyHex,
          );
        } else {
          // Self is non-admin. Drive the Leave UI.
          await _leaveCircleAsNonAdmin(tester: tester);
        }
      } on Object {
        // Flush observable state into logcat before re-throwing so the
        // CI failure artifact carries enough context to triage without
        // re-running locally.
        await dumpScenarioState(
          tester: tester,
          ctx: ctx,
          label: 'e2e_combined_failure_${ctx.role.name}',
        );
        rethrow;
      }
    },
    timeout: const Timeout(_outerTestTimeout),
  );
}

// =============================================================================
// PHASE 2 helpers — circle establishment
// =============================================================================

/// Alice's leg of PHASE 2: wait for BOTH peers' KeyPackages, drive
/// `Create Circle` with two npubs, wait for both gift-wraps.
///
/// The two-KP wait happens in parallel via `Future.wait` so a slower
/// peer doesn't serialize the budget; the same goes for the gift-wrap
/// future pair. Total wall-clock is `max(KPs) + create + max(gift-wraps)`
/// not their sum.
///
/// **Follow-up — post-creation member addition (tracked separately):**
/// when the production UI gains an "Add member to existing circle"
/// affordance and a Dart-side `CircleService.addMembers` wrapper (the
/// FFI exists at `haven/rust_builder/src/api.rs:1853` but is not yet
/// exposed through the service layer), split this into a two-phase
/// sub-flow:
/// (1) Alice creates a 2-member circle with Bob, Bob accepts and
/// they see each other; (2) Alice adds Carol via the new affordance,
/// Carol accepts and all three see each other. That sub-flow
/// exercises the post-creation Update-commit + multi-recipient
/// Welcome path which is functionally distinct from the genesis
/// path tested here.
Future<void> _aliceCreatesThreeMemberCircle({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String bobPubkeyHex,
  required String bobNpub,
  required String carolPubkeyHex,
  required String carolNpub,
}) async {
  // Both peers' KeyPackages must be on the relay before the member-
  // search can resolve them. Each peer's MapShell mount triggers the
  // KP publish; on a warm run both land within seconds.
  await Future.wait(<Future<void>>[
    waitForKeyPackage(
      relay: ctx.relay,
      authorPubkeyHex: bobPubkeyHex,
      timeout: _peerKeyPackageDeadline,
    ),
    waitForKeyPackage(
      relay: ctx.relay,
      authorPubkeyHex: carolPubkeyHex,
      timeout: _peerKeyPackageDeadline,
    ),
  ]);

  // Open BOTH gift-wrap subscriptions BEFORE the publish so we never
  // miss the events. NIP-59 gift-wraps use ephemeral outer keys, so
  // we filter by recipient `#p` tag rather than by author.
  final bobGiftWrapFuture = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: bobPubkeyHex,
    timeout: _giftWrapDeadline,
  );
  final carolGiftWrapFuture = waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: carolPubkeyHex,
    timeout: _giftWrapDeadline,
  );

  // Expand the draggable bottom sheet to bring the empty-state CTA
  // into the viewport. The retry-aware helper avoids the velocity-
  // tracker flake the synthetic-drag pattern is prone to on slow
  // CI emulators (see sheet_helpers.dart).
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.byKey(WidgetKeys.circlesCreateCta),
  );

  await tester.tap(find.byKey(WidgetKeys.circlesCreateCta));
  await tester.pumpAndSettle();

  // Member selection — enter both npubs and submit each via the IME
  // done action. The bar validates each npub against the relay via
  // a KeyPackage fetch; the production `_selectedMembers` list grows
  // by one entry per validated npub.
  expect(find.byType(CreateCirclePage), findsOneWidget);

  await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), bobNpub);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();

  await tester.enterText(find.byKey(WidgetKeys.memberSearchInput), carolNpub);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();

  // Continue is gated on every selected member reaching `valid`. With
  // two valid members, the button becomes tappable.
  final continueBtn = find.byKey(WidgetKeys.createCircleContinue);
  expect(continueBtn, findsOneWidget);
  await tester.tap(continueBtn);
  await tester.pumpAndSettle();

  // NameCirclePage — type the circle name, tap Create.
  expect(find.byType(NameCirclePage), findsOneWidget);
  await tester.enterText(
    find.byKey(WidgetKeys.circleNameInput),
    _circleName,
  );
  await tester.tap(find.byKey(WidgetKeys.createCircleConfirm));
  await tester.pumpAndSettle();

  // Back on MapShell with the new circle.
  expect(find.byType(MapShell), findsOneWidget);
  expect(
    find.textContaining(_circleName),
    findsAtLeastNWidgets(1),
    reason:
        'After Create Circle returns, either the SnackBar or the new '
        'circle tile must be visible on the map shell.',
  );

  // Both gift-wraps must have landed on the relay; without them the
  // peers' accept flow has nothing to consume. `Future.wait` returns
  // `Future<List<TestRelayEvent>>` here — we ignore the values, we
  // only need to know both completed without throwing.
  await Future.wait<TestRelayEvent>(
    <Future<TestRelayEvent>>[bobGiftWrapFuture, carolGiftWrapFuture],
  );

  debugPrint('[e2e_combined:alice] PHASE 2 complete (3-member circle).');
}

/// Generic accept-invitation helper used by both Bob and Carol. The
/// flow is identical for both roles — wait for the gift-wrap, open
/// InvitationsPage, refresh until Accept appears, tap Accept, return
/// to MapShell, assert the circle is in the bottom sheet, then verify
/// the resulting MLS membership set matches [expectedMemberPubkeys].
///
/// The membership assertion is the protocol-level guard against a
/// MIP-02 / NIP-59 regression where the kind-444 rumor inside the
/// gift-wrap is wrapped to the wrong recipient. The outer `#p` filter
/// only proves a 1059 *envelope* was addressed to the recipient — if
/// the inner rumor targets a different KeyPackage, MDK rejects the
/// accept and we'd see it here as `members.length` being 1 (self
/// only after Alice's create commit failed to land on this role).
Future<void> _acceptInvitation({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String selfPubkeyHex,
  required String roleLabel,
  required List<String> expectedMemberPubkeys,
}) async {
  // Gate UI actions on the actual gift-wrap landing — the production
  // invitation-poller cannot see anything before then; tapping Accept
  // first would either find nothing or race the fetch.
  await waitForGiftWrap(
    relay: ctx.relay,
    recipientPubkeyHex: selfPubkeyHex,
    timeout: _giftWrapDeadline,
  );

  // pumpUntilFound instead of pumpAndSettle — MapShell's periodic
  // timers keep the frame queue non-empty so pumpAndSettle would
  // hang until its 10-min internal timeout. See pump_helpers.dart.
  await tester.tap(find.byKey(WidgetKeys.invitationsFloatingButton));
  await pumpUntilFound(
    tester,
    find.byType(InvitationsPage),
    timeout: const Duration(seconds: 15),
    description: 'InvitationsPage after tapping floating button',
  );

  // The Accept button may take a beat after the page mounts —
  // InvitationsPage auto-polls in initState. Retry the refresh
  // button if the list is still loading.
  for (var attempt = 0; attempt < 5; attempt++) {
    if (find.text('Accept').evaluate().isNotEmpty) break;
    await tester.tap(find.byKey(WidgetKeys.invitationsRefresh));
    await pumpUntilFound(
      tester,
      find.text('Accept'),
      timeout: const Duration(seconds: 10),
      description: 'Accept button after tapping refresh (attempt $attempt)',
    ).catchError((Object _) {
      // Swallow the per-attempt miss; the outer expect surfaces a
      // clean failure if all attempts run out.
    });
  }
  expect(
    find.text('Accept'),
    findsOneWidget,
    reason:
        '$roleLabel expected exactly one Accept button on the '
        'InvitationsPage after the gift-wrap landed.',
  );

  // Tapping Accept fires accept_invitation which performs an MDK
  // epoch advance and invalidates `circlesProvider`. The cleanest
  // observable is the Accept button disappearing from the tree.
  await tester.tap(find.text('Accept'));
  await pumpUntilGone(
    tester,
    find.text('Accept'),
    description: 'Accept button disappearing after accept_invitation',
  );

  // Some implementations pop back to MapShell; others leave the
  // user on InvitationsPage with an empty state. Handle both.
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

  // Expand the sheet so the circle list is visible. The retry-aware
  // helper guarantees the assertion checks a *layout* fact (does the
  // circle appear in the visible roster) rather than racing with the
  // sheet's snap animation.
  await expandCirclesSheetToMax(
    tester,
    targetFinder: find.textContaining(_circleName),
  );
  expect(
    find.textContaining(_circleName),
    findsAtLeastNWidgets(1),
    reason:
        'After acceptInvitation, the circle "$_circleName" must appear '
        "in $roleLabel's circle list.",
  );

  // Protocol-level membership assertion (Marmot F2). Confirms that
  // every expected pubkey is present in this role's MDK view AND that
  // there are no extras. A 1059 wrapped to the wrong recipient would
  // either leave `members` at 1 (just self) or — if MDK still accepts
  // the rumor for the wrong identity — surface a stray pubkey here.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(circlesProvider);
  final circles = await container.read(circlesProvider.future);
  final myCircle = circles.firstWhere(
    (c) => c.displayName == _circleName,
    orElse: () => throw StateError(
      '$roleLabel: circle "$_circleName" missing from circlesProvider '
      'after acceptInvitation returned successfully.',
    ),
  );
  final expectedSet = expectedMemberPubkeys
      .map((p) => p.toLowerCase())
      .toSet();
  final actualSet = myCircle.members
      .map((m) => m.pubkey.toLowerCase())
      .toSet();
  expect(
    actualSet,
    equals(expectedSet),
    reason:
        '$roleLabel: member set mismatch after acceptInvitation. '
        'Expected ${expectedSet.length} members; got '
        '${actualSet.length}. This is a strong signal that either '
        "the gift-wrap's inner Welcome targeted the wrong KeyPackage "
        '(MIP-02 / NIP-59 regression) or MDK failed to fully apply '
        "Alice's create-circle commit on $roleLabel's side.",
  );

  debugPrint('[e2e_combined:$roleLabel] PHASE 2 complete (joined).');
}

// =============================================================================
// PHASE 3 helpers — three-way location sharing
// =============================================================================

/// Forces a location publish and waits until BOTH peer markers appear
/// on the map for this role.
///
/// The bounded-retry loop is the canonical pattern from scenario_03:
/// invalidate `locationPublisherProvider`, await it, invalidate
/// `memberLocationsProvider`, await it, pump a handful of frames,
/// check the finders. The MLS epoch race can briefly produce empty
/// results (Bob's epoch hasn't caught up to Alice's commit), so the
/// retries absorb that window.
Future<void> _publishLocationAndObservePeers({
  required WidgetTester tester,
  required List<String> peerPubkeyHexes,
  required ScenarioContext ctx,
}) async {
  // Force a fresh publish AFTER all roles have settled into MapShell.
  // Production auto-publishes after circle creation and after accept,
  // but those auto-publishes might land before all peers' MLS groups
  // are fully merged. Re-firing explicitly gives every receiver a
  // fresh kind-445 event AFTER acceptInvitation completed.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(locationPublisherProvider);
  final publishedCount = await container.read(
    locationPublisherProvider.future,
  );
  expect(
    publishedCount,
    greaterThanOrEqualTo(1),
    reason:
        'locationPublisherProvider must have published to at least '
        'one accepted circle; got 0 which means encryptLocation '
        'either no-op-ed or no accepted circles exist for this role.',
  );

  // Wait for at least one kind-445 event on the relay independent of
  // UI state. This catches an encryptLocation no-op even if the UI
  // assertion would otherwise pass vacuously.
  final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      'since': cutoff,
      'limit': 50,
    },
    timeout: _locationEventDeadline,
  );

  // Retry the invalidate+read cycle until `memberLocationsProvider`
  // contains a location entry for every expected peer pubkey.
  //
  // Why we assert on the provider rather than on widget keys:
  //   `flutter_map`'s `MarkerLayer` unconditionally culls markers
  //   whose pixel position falls outside the current viewport — see
  //   `flutter_map/lib/src/layer/marker_layer/marker_layer.dart`,
  //   the early `return null` in `getPositioned()`. The culled
  //   marker's `Positioned` is never added to the layer's `Stack`,
  //   so `find.byKey(WidgetKeys.memberMarker(<pk>))` returns empty
  //   regardless of what's in `memberLocationsProvider`. At the
  //   `MapPage` default zoom Alice's map centres at her own fake
  //   GPS (12.345, 87.654); Bob (13.456, 89.876) and Carol (14.567,
  //   91.098) are tens of thousands of pixels off-viewport and
  //   therefore never reachable through the widget-tree finder.
  //
  //   The data-layer assertion below verifies the full integration
  //   we care about for this scenario: encrypt → publish → relay →
  //   fetch → decrypt → persist → provider. The rendering of those
  //   provider entries as `MemberMarker` widgets is covered by the
  //   plain unit test in `test/pages/map/map_page_test.dart`, where
  //   the viewport is controlled by the test author.
  //
  // The 8×5s retry budget absorbs the MLS epoch race; the final
  // assertion has a clean miss reason if any peer's location never
  // materializes in the provider.
  //
  // TODO(efe): wait-for-epoch. When `wait_for_epoch_for_test`
  // (haven/rust_builder/src/api.rs:3143) is wired up, replace this
  // retry budget with a deterministic epoch-target wait so peer-
  // location-publish races become impossible by construction.
  //
  // Lowercase the pubkeys upfront — production `manager.rs:705`
  // already returns lowercase hex, but normalizing here makes the
  // test robust against an upstream `pubkeyHex` formatting change.
  final missingPeers =
      peerPubkeyHexes.map((p) => p.toLowerCase()).toSet();
  for (var attempt = 0; attempt < 8 && missingPeers.isNotEmpty; attempt++) {
    container
      ..invalidate(locationPublisherProvider)
      ..invalidate(evolutionPollerProvider)
      ..invalidate(memberLocationsProvider);
    await container.read(locationPublisherProvider.future);
    // Driving the evolution poller alongside the location publisher
    // ensures kind-445 commit messages received between fetch ticks
    // get processed and their decrypted locations land in the cache
    // — without this, the production EvolutionPoller-vs-fetch race
    // (now fixed in `location_sharing_service.dart`) was the root
    // cause of Carol missing Alice's location in CI.
    await container.read(evolutionPollerProvider.future);
    final locations = await container.read(memberLocationsProvider.future);

    // Three bounded pumps cover any UI rebuild listeners that the
    // provider read may have scheduled. We do not depend on the
    // global frame queue draining (MapShell's periodic timers keep
    // it perpetually non-empty under IntegrationTestWidgetsFlutterBinding).
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final presentPubkeys = locations
        .map((loc) => loc.pubkey.toLowerCase())
        .toSet();
    missingPeers.removeWhere(presentPubkeys.contains);
    if (missingPeers.isEmpty) break;

    debugPrint(
      '[e2e_combined:${ctx.role.name}] PHASE 3 attempt $attempt — '
      'memberLocationsProvider missing ${missingPeers.length} peers '
      '(present=${presentPubkeys.length})',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    missingPeers,
    isEmpty,
    reason:
        '${ctx.role.name}: memberLocationsProvider did not contain '
        'entries for every expected peer within the retry budget. '
        'Either decryptLocation returned null for some peer (FFI '
        "regression), the MLS epoch race didn't converge, the peer's "
        'locationPublisherProvider failed to publish, or the '
        'EvolutionPoller-vs-fetch race in `location_sharing_service.dart` '
        'has regressed.',
  );

  debugPrint(
    '[e2e_combined:${ctx.role.name}] PHASE 3 complete '
    '(${peerPubkeyHexes.length} peer locations in provider).',
  );
}

// =============================================================================
// PHASE 4 helpers — admin leave with handoff
// =============================================================================

/// Alice's flow: open the circle-details modal, tap Leave Circle,
/// confirm the dialog, assert the circle is gone from her list. The
/// UI path is identical to a non-admin Leave — `LeavePlan::AdminHandoff`
/// runs invisibly underneath, promoting the lex-smallest non-self
/// member to admin, self-demoting, and publishing the SelfRemove.
Future<void> _aliceLeavesCircle({required WidgetTester tester}) async {
  final detailsButton = find.byTooltip('Circle details');
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        "After PHASE 2/3, Alice's selected-circle header with its "
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

  // Confirmation dialog. The "Leave" TextButton is distinct from the
  // dialog title "Leave Circle"; widgetWithText is the unambiguous
  // selector.
  final leaveConfirm = find.widgetWithText(TextButton, 'Leave');
  expect(leaveConfirm, findsOneWidget);
  await tester.tap(leaveConfirm);
  // FFI: planLeave (AdminHandoff) → proposeAdminHandoff → publish →
  // finalize → proposeSelfDemote → publish → finalize → proposeLeave →
  // publish → completeLeave. Three relay round-trips on Alice's side.
  //
  // pumpUntilGone, not pumpAndSettle (Flutter F1): the dialog pops
  // immediately when the tap is processed, then the async FFI chain
  // begins. pumpAndSettle can see a momentarily-empty frame queue
  // BETWEEN the dialog close and the next FFI await, settle
  // prematurely, and let the next `expect(... findsNothing)` fire
  // while the chain is still in flight. Waiting on the actual
  // observable — the circle name leaving the widget tree — gates
  // the next assertion on the work being done.
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
}

/// Bob/Carol's flow: wait for Alice's three-commit AdminHandoff
/// sequence to land on the relay (scoped to this circle's
/// `nostr_group_id` to avoid catching unrelated kind-445 traffic),
/// drive the evolution poller + member-locations provider until
/// Alice's tile disappears, then assert the residual two-member
/// group has exactly one admin.
///
/// The filter scoping with `#h` (Marmot F3/F4) protects against
/// `locationPublisherProvider`'s 30-second timer firing during the
/// four-minute admin-handoff deadline — without the scope, a
/// well-timed location-publish kind-445 from any peer could inflate
/// the `collectN(count: 3)` total and let the test pass even when
/// only two of the three handoff commits actually landed.
Future<void> _observeAliceDeparture({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String alicePubkeyHex,
}) async {
  // Resolve this role's nostr_group_id BEFORE waiting on the relay
  // so the `#h` filter scope can be applied. The id is required
  // again later for the diagnostic dump. Pulling it up here is also
  // what unblocks the FFI-first retry pattern below.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );
  final preLeaveCircles = await container.read(circlesProvider.future);
  final preLeaveCircle = preLeaveCircles.firstWhere(
    (c) => c.displayName == _circleName,
    orElse: () => throw StateError(
      '${ctx.role.name} has no circle named "$_circleName" before '
      'PHASE 4 even started — earlier phases must have failed.',
    ),
  );
  final myNostrGroupIdHex = _bytesToHex(preLeaveCircle.nostrGroupId);

  // Two-second backstop on the `since` cutoff absorbs NIP-01's
  // permitted ~1–2 s clock-skew between the publisher and the
  // relay's `created_at` enforcement (Marmot F8). Without it, a
  // slightly-in-the-past created_at would drop the first
  // AdminHandoff commit and the collectN would silently stall.
  final cutoff =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 2;

  // LeavePlan::AdminHandoff emits exactly three commits in sequence:
  // AdminHandoff → SelfDemote → SelfRemove. Wait for all three to
  // land before asking MDK to apply them. The four-minute budget
  // covers Alice's three relay round-trips on a cold AVD.
  const expectedCommits = 3;
  final allCommits = await ctx.relay.collectN(
    count: expectedCommits,
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      // Scope to this circle: nostr_group_id is by-design public
      // and stable per MIP-03; scoping eliminates the inflated-
      // count failure mode driven by background location traffic.
      '#h': <String>[myNostrGroupIdHex],
      'since': cutoff,
      'limit': 50,
    },
    timeout: _adminHandoffDeadline,
  );
  expect(
    allCommits.length,
    greaterThanOrEqualTo(expectedCommits),
    reason:
        '${ctx.role.name} expected $expectedCommits scoped kind-445 '
        'commit events (#h=${_redactPubkey(myNostrGroupIdHex)}) '
        'within ${_adminHandoffDeadline.inMinutes} min '
        '(AdminHandoff + SelfDemote + SelfRemove); only saw '
        '${allCommits.length}. Either Alice never finished her '
        'three-step leave, the relay dropped events, or the '
        'nostr_group_id mismatch surfaced by the diagnostic dump '
        'below excluded the commits.',
  );

  // Diagnostic: surface the `#h` tag of every commit alongside the
  // nostr_group_id this role is filtering by. Even with the `#h`
  // scope above, the dump is useful when investigating a
  // partial-fetch: a mismatch here on a commit that DID pass the
  // `#h` filter would indicate a strfry filter-match bug or a
  // historical artifact from before the nostr_group_id rotation
  // was fixed.
  debugPrint(
    '[diagnostics:e2e_combined_handoff] '
    '${ctx.role.name}.circle.nostrGroupId='
    '${_redactPubkey(myNostrGroupIdHex)}',
  );
  for (final commit in allCommits) {
    final hTag = commit.tag('h');
    final hTagValue =
        hTag != null && hTag.length >= 2 ? hTag[1] : 'none';
    debugPrint(
      '[diagnostics:e2e_combined_handoff] '
      'commit eventId=${_redactPubkey(commit.id)} '
      '#h=${_redactPubkey(hTagValue)} '
      'matchesMe=${hTagValue == myNostrGroupIdHex}',
    );
  }

  // FFI-first retry: source of truth is `CircleManagerFfi.getMembers`
  // (surfaced through circlesProvider). The UI tile is derived state
  // — checking FFI first means a failure pinpoints whether MDK has
  // applied the commits (FFI says Alice is gone) or whether the
  // bug is in the UI rebuild path (FFI says Alice is gone but tile
  // is still present). The retry budget absorbs the MLS epoch race
  // while the evolution poller catches up.
  //
  // TODO(efe): wait-for-epoch. When `wait_for_epoch_for_test`
  // (haven/rust_builder/src/api.rs:3143) is wired up, replace this
  // retry budget with a deterministic epoch-target wait.
  final aliceTile = WidgetKeys.memberTile(alicePubkeyHex);
  final lowerAlice = alicePubkeyHex.toLowerCase();
  var aliceGoneInFfi = false;
  var aliceGoneInUi = false;
  Circle? postLeaveCircle;
  for (
    var attempt = 0;
    attempt < 8 && !(aliceGoneInFfi && aliceGoneInUi);
    attempt++
  ) {
    container
      ..invalidate(evolutionPollerProvider)
      ..invalidate(memberLocationsProvider)
      ..invalidate(circlesProvider);
    await container.read(evolutionPollerProvider.future);
    await container.read(memberLocationsProvider.future);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // FFI source of truth.
    final freshCircles = await container.read(circlesProvider.future);
    final matching = freshCircles
        .where((c) => c.displayName == _circleName)
        .toList(growable: false);
    if (matching.isEmpty) {
      // The whole circle vanished from our view — would indicate WE
      // got removed instead of Alice. That's a different bug, but
      // we stop the loop and let the outer assertion surface it.
      postLeaveCircle = null;
      break;
    }
    postLeaveCircle = matching.first;
    aliceGoneInFfi = !postLeaveCircle.members.any(
      (m) => m.pubkey.toLowerCase() == lowerAlice,
    );

    // UI derived state.
    aliceGoneInUi = find.byKey(aliceTile).evaluate().isEmpty;

    if (aliceGoneInFfi && aliceGoneInUi) break;

    debugPrint(
      '[e2e_combined:${ctx.role.name}] PHASE 4 attempt $attempt — '
      'aliceGoneInFfi=$aliceGoneInFfi aliceGoneInUi=$aliceGoneInUi',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    aliceGoneInFfi,
    isTrue,
    reason:
        '${ctx.role.name}: FFI member list still contains Alice (pubkey '
        '${_redactPubkey(alicePubkeyHex)}) after the three-commit leave '
        'and the retry budget expired. The evolution poller did not '
        "apply Alice's commits — check MDK epoch state and the "
        '#h scoping above.',
  );
  expect(
    aliceGoneInUi,
    isTrue,
    reason:
        '${ctx.role.name}: FFI agrees Alice has left but the UI member '
        'tile (pubkey ${_redactPubkey(alicePubkeyHex)}) is still in the '
        'tree. The bug is in the provider→sheet rebuild path, not in '
        'MLS state.',
  );

  // Residual-group invariants (Marmot F5):
  //   - Exactly 2 members remain (Bob + Carol).
  //   - Exactly 1 of them is admin (the lex-smaller non-Alice member,
  //     per select_successor in haven-core/src/circle/leave.rs).
  // The non-null assertion is safe: the FFI-gone assertion above
  // already proved the circle is still in our view.
  final residual = postLeaveCircle!;
  expect(
    residual.members.length,
    equals(2),
    reason:
        '${ctx.role.name}: residual member count after Alice left is '
        '${residual.members.length}, expected exactly 2. Either Alice '
        'remained, the other peer was inadvertently removed, or the '
        "committed MDK group state diverged from Haven's expectation.",
  );
  final adminCount = residual.members.where((m) => m.isAdmin).length;
  expect(
    adminCount,
    equals(1),
    reason:
        '${ctx.role.name}: residual group has $adminCount admins, '
        'expected exactly 1. A 0-admin state means proposeAdminHandoff '
        'was skipped in LeavePlan::AdminHandoff; a 2-admin state means '
        'AdminHandoff promoted the successor but the subsequent '
        'SelfDemote did not apply.',
  );

  debugPrint('[e2e_combined:${ctx.role.name}] PHASE 4 complete.');
}

// =============================================================================
// PHASE 5 helpers — non-admin leave from residual 2-member group
// =============================================================================

/// Reads `circlesProvider`, finds this role's entry in the circle's
/// member list, and returns the `isAdmin` flag.
///
/// Called *after* PHASE 4 has settled — at that point exactly one of
/// Bob/Carol holds isAdmin=true.
Future<bool> _selfIsAdmin({
  required WidgetTester tester,
  required String selfPubkeyHex,
}) async {
  // Force a fresh read so the post-handoff membership view is up
  // to date — without invalidate, a stale snapshot from Phase 3
  // could mask a regression where the handoff never updated the
  // admin set.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  )..invalidate(circlesProvider);
  final circles = await container.read(circlesProvider.future);
  final myCircle = circles.firstWhere(
    (c) => c.displayName == _circleName,
    orElse: () => throw StateError(
      'Cannot determine admin status: no circle named "$_circleName" '
      'in this role. The residual group should still contain this '
      'role after Alice left.',
    ),
  );
  final me = myCircle.members.firstWhere(
    (m) => m.pubkey.toLowerCase() == selfPubkeyHex.toLowerCase(),
    orElse: () => throw StateError(
      'Cannot determine admin status: this role is not in the circle '
      'member list. The leave flow may have removed the wrong member.',
    ),
  );
  return me.isAdmin;
}

/// Non-admin's leg of PHASE 5 — drive the Leave Circle UI exactly as
/// in PHASE 4 for Alice. The leave is a single SelfRemove proposal
/// (`LeavePlan::NonAdmin`); there's no handoff because the residual
/// admin is staying.
Future<void> _leaveCircleAsNonAdmin({required WidgetTester tester}) async {
  final detailsButton = find.byTooltip('Circle details');
  expect(
    detailsButton,
    findsOneWidget,
    reason:
        "After PHASE 4, the non-admin's selected-circle header with "
        'its "Circle details" info button must be visible in the '
        'bottom sheet.',
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
  // FFI: planLeave (NonAdmin) → proposeLeave → publish →
  // completeLeave. One relay round-trip. Same pumpUntilGone
  // rationale as Alice's leave above (Flutter F1).
  await pumpUntilGone(
    tester,
    find.text(_circleName),
    timeout: const Duration(seconds: 60),
    description:
        'circle "$_circleName" tile disappearing after non-admin '
        'taps Leave',
  );

  expect(find.byType(MapShell), findsOneWidget);
  expect(
    find.text(_circleName),
    findsNothing,
    reason:
        'After non-admin Leave returns, the circle "$_circleName" must '
        "no longer appear in this role's circle list.",
  );
}

/// Admin's leg of PHASE 5 — wait for the non-admin's SelfRemove kind-
/// 445 commit to land (scoped to this circle's `nostr_group_id`),
/// then drive evolution + memberLocations until the leaver's tile is
/// gone. Same FFI-first retry pattern as `_observeAliceDeparture`.
Future<void> _observeNonAdminLeave({
  required WidgetTester tester,
  required ScenarioContext ctx,
  required String otherPubkeyHex,
}) async {
  // Resolve nostr_group_id for the `#h` filter scope and cutoff slack.
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HavenApp)),
    listen: false,
  );
  final preLeaveCircles = await container.read(circlesProvider.future);
  final preLeaveCircle = preLeaveCircles.firstWhere(
    (c) => c.displayName == _circleName,
    orElse: () => throw StateError(
      '${ctx.role.name} has no circle named "$_circleName" before '
      'PHASE 5 even started — earlier phases must have failed.',
    ),
  );
  final myNostrGroupIdHex = _bytesToHex(preLeaveCircle.nostrGroupId);
  final cutoff =
      (DateTime.now().millisecondsSinceEpoch ~/ 1000) - 2;

  // Non-admin's `LeavePlan::NonAdmin` emits exactly one SelfRemove
  // proposal as a kind-445. The hermetic relay scope + `#h` filter
  // prevent location-publish ticks from being mistaken for the
  // leave commit.
  await ctx.relay.firstWhere(
    filter: <String, dynamic>{
      'kinds': const <int>[445],
      '#h': <String>[myNostrGroupIdHex],
      'since': cutoff,
      'limit': 20,
    },
    timeout: _nonAdminLeaveDeadline,
  );

  final otherTile = WidgetKeys.memberTile(otherPubkeyHex);
  final lowerOther = otherPubkeyHex.toLowerCase();
  var otherGoneInFfi = false;
  var otherGoneInUi = false;
  for (
    var attempt = 0;
    attempt < 8 && !(otherGoneInFfi && otherGoneInUi);
    attempt++
  ) {
    container
      ..invalidate(evolutionPollerProvider)
      ..invalidate(memberLocationsProvider)
      ..invalidate(circlesProvider);
    await container.read(evolutionPollerProvider.future);
    await container.read(memberLocationsProvider.future);

    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    final freshCircles = await container.read(circlesProvider.future);
    final matching = freshCircles
        .where((c) => c.displayName == _circleName)
        .toList(growable: false);
    if (matching.isEmpty) {
      // Circle vanished from admin's view — that's a different bug,
      // we stop and let the outer assertions surface it.
      break;
    }
    otherGoneInFfi = !matching.first.members.any(
      (m) => m.pubkey.toLowerCase() == lowerOther,
    );
    otherGoneInUi = find.byKey(otherTile).evaluate().isEmpty;

    if (otherGoneInFfi && otherGoneInUi) {
      break;
    }
    debugPrint(
      '[e2e_combined:${ctx.role.name}] PHASE 5 attempt $attempt — '
      'otherGoneInFfi=$otherGoneInFfi otherGoneInUi=$otherGoneInUi',
    );
    await Future<void>.delayed(const Duration(seconds: 5));
  }
  expect(
    otherGoneInFfi,
    isTrue,
    reason:
        '${ctx.role.name}: FFI member list still contains the non-admin '
        '(pubkey ${_redactPubkey(otherPubkeyHex)}) after their SelfRemove '
        'and the retry budget expired. The evolution poller did not '
        'apply the commit — check MDK epoch state and the #h scoping above.',
  );
  expect(
    otherGoneInUi,
    isTrue,
    reason:
        '${ctx.role.name}: FFI agrees the non-admin has left but the UI '
        'member tile (pubkey ${_redactPubkey(otherPubkeyHex)}) is still '
        'in the tree. The bug is in the provider→sheet rebuild path, '
        'not in MLS state.',
  );

  // Residual sole-member invariant: admin is the only one left.
  // This is the single-member group state that the production
  // `LeavePlan::Abandon` path would handle on the *next* leave; we
  // don't drive that here (see docstring), but we assert the count.
  final finalCircles = await container.read(circlesProvider.future);
  final finalCircleMatch = finalCircles
      .where((c) => c.displayName == _circleName)
      .toList(growable: false);
  expect(
    finalCircleMatch,
    hasLength(1),
    reason:
        '${ctx.role.name}: residual circle "$_circleName" missing from '
        "admin's view after non-admin left. Admin must still see the "
        '(now sole-member) circle.',
  );
  expect(
    finalCircleMatch.first.members.length,
    equals(1),
    reason:
        '${ctx.role.name}: residual member count after non-admin left is '
        '${finalCircleMatch.first.members.length}, expected exactly 1 (the '
        'admin themselves). A larger count means the SelfRemove did not '
        'evict the leaver from MDK state.',
  );

  debugPrint('[e2e_combined:${ctx.role.name}] PHASE 5 complete.');
}

// =============================================================================
// Misc helpers
// =============================================================================

LocationService _fakeLocationFor(ScenarioRole role) {
  return switch (role) {
    ScenarioRole.alice => FakeLocationService(
      latitude: aliceFakeLatitude,
      longitude: aliceFakeLongitude,
    ),
    ScenarioRole.bob => FakeLocationService(
      latitude: bobFakeLatitude,
      longitude: bobFakeLongitude,
    ),
    ScenarioRole.carol => FakeLocationService(
      latitude: carolFakeLatitude,
      longitude: carolFakeLongitude,
    ),
    ScenarioRole.solo => throw UnimplementedError(
      'e2e_combined does not support ScenarioRole.solo',
    ),
  };
}

String _selfPubkeyHexFor(
  ScenarioRole role, {
  required String alice,
  required String bob,
  required String carol,
}) {
  return switch (role) {
    ScenarioRole.alice => alice,
    ScenarioRole.bob => bob,
    ScenarioRole.carol => carol,
    ScenarioRole.solo => throw UnimplementedError(
      'e2e_combined does not support ScenarioRole.solo',
    ),
  };
}

/// Returns the first 8 hex chars + `…` for use in log lines.
///
/// The full pubkey is public-by-design Nostr metadata, but truncating
/// in log output reduces casual leakage in screenshots and shared
/// failure artifacts. The full value is still accessible via the
/// scenario state dumper when needed.
String _redactPubkey(String hex) {
  if (hex.length <= 8) return hex;
  return '${hex.substring(0, 8)}…';
}

/// Lowercase hex encoding of [bytes]. Inlined rather than re-exporting
/// `test_user.dart::bytesToHex` to avoid a public-API dependency.
String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
