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
import 'package:flutter/material.dart' show FilledButton, SizedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/circles/add_member_page.dart';
import 'package:haven/src/pages/circles/create_circle_page.dart';
import 'package:haven/src/pages/circles/name_circle_page.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart';
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider;
import 'package:haven/src/providers/invitation_provider.dart'
    show pendingInvitationsProvider;
import 'package:haven/src/providers/key_package_provider.dart'
    show keyPackagePublisherProvider;
import 'package:haven/src/providers/live_sync_provider.dart'
    show liveSyncEnabled;
import 'package:haven/src/providers/location_sharing_provider.dart';
import 'package:haven/src/providers/maintenance_scheduler_provider.dart'
    show MaintenanceSchedulerNotifier, maintenanceSchedulerProvider;
import 'package:haven/src/providers/onboarding_provider.dart';
import 'package:haven/src/providers/relay_preferences_provider.dart'
    show inboxRelaysProvider;
import 'package:haven/src/providers/service_providers.dart';
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleFfi,
        CircleWithMembersFfi,
        InvitationFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/circle_service.dart' show Circle, MembershipStatus;
import 'package:haven/src/services/live_sync_resubscriber.dart'
    show LiveSyncResubscriber;
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

/// Bound on the one-shot `await container.read(locationPublisherProvider
/// .future)` calls in this file (Alice's post-create and post-add
/// publishes) — used wherever we force a specific Riverpod poller
/// provider's `.future` directly (as opposed to reading its current
/// `AsyncValue` synchronously, which cannot be orphaned; see the PHASE 4
/// convergence probe below for why the awaited-`.future` shape was dropped
/// there entirely).
///
/// `locationPublisherProvider` is ALSO invalidated in the BACKGROUND while
/// Alice's real `MapShell` is mounted — its own `_guardedPublish` timer/
/// motion-trigger invalidate + read it on an independent cadence. If that
/// background invalidation lands between OUR `invalidate()` and OUR
/// `.future` read of the SAME provider, Riverpod discards the stale build
/// our read captured a reference to — the `Future` we are awaiting can
/// then never resolve, or resolves much later, after this test method has
/// already returned. A bare, unbounded `await` here would hang the whole
/// call until the harness-level test timeout (these are one-shot calls
/// with no `_pollUntil` wrapper to fall back on) — and worse, the
/// abandoned `async` frame can resume AFTER that timeout fires, calling
/// into an already-torn-down `WidgetTester`/binding and tripping
/// `!inTest` in the NEXT test. Wrapping the read in
/// `.timeout(_riverpodPollerReadTimeout)` guarantees OUR `await` always
/// settles within a small, deterministic window regardless of whether the
/// underlying provider Future was orphaned.
const Duration _riverpodPollerReadTimeout = Duration(seconds: 10);

/// Tolerance when comparing a decrypted coordinate to its sentinel.
///
/// The sentinel coords are plain f64 constants round-tripped through
/// kind-9 JSON → Rust → Dart; the loss is sub-ULP. 1e-5 (~1 m of
/// latitude) is far wider than any round-trip noise yet orders of
/// magnitude tighter than any real corruption, so it detects a
/// decrypt-but-corrupt bug without risking float-precision flake.
const double _coordEpsilon = 1e-5;

// =============================================================================
// Shared ProviderScope overrides
// =============================================================================

/// Inert stand-in for [MaintenanceSchedulerNotifier] that arms no timers.
///
/// `MapShell.initState` reads `maintenanceSchedulerProvider.notifier`, which
/// in production arms three self-rescheduling `KeyPackage`/relay-list/
/// subscription-health timers doing real FFI + relay round-trips (see
/// `maintenance_scheduler_provider.dart`). Nothing in this file reads the
/// scheduler's output — it has its own dedicated unit tests
/// (`test/providers/maintenance_scheduler_provider_test.dart`), and the
/// health-tick re-anchor path is a deferred backlog item, not an M11
/// scenario — so disabling it here loses zero coverage while removing a
/// source of unattributed relay/FFI contention (and, on the last M11
/// scenario, a timer that would otherwise leak into `tearDownAll`).
///
/// The base class's ONLY timer-arming call sites (`_armKeyPackage`,
/// `_armRelayList`, `_armHealth`) are invoked from `build()` — so overriding
/// `build()` to a no-op (never calling `super.build()`) leaves every
/// `Timer?` field `null` for this instance's whole lifetime; no other method
/// arms a timer independently of `build()`.
class _InertMaintenanceScheduler extends MaintenanceSchedulerNotifier {
  @override
  void build() {}
}

/// Shared `ProviderScope` overrides for every `HavenApp` pump in this file —
/// the main scenario's pump and `_m11PumpAliceLiveEngine`. Centralizing the
/// maintenance-scheduler no-op keeps both pump sites in lockstep; each call
/// site still appends its own scenario-specific overrides (the onboarding
/// controller and the fake location service) alongside this list.
List<Override> _e2eProviderOverrides() => [
  maintenanceSchedulerProvider.overrideWith(_InertMaintenanceScheduler.new),
];

// =============================================================================
// Bounded teardown
// =============================================================================

/// Bound on every best-effort `tearDownAll` cleanup await (peer/relay
/// dispose, identity clearing). None of these calls previously had a
/// timeout, so a stuck dispose (e.g. a stale WebSocket close deep in a
/// `TestRelay`) hung invisibly until CI's outer SIGKILL with no per-cleanup
/// attribution. 15 s is generous for every cleanup this file performs today
/// (in-memory teardown + at most one relay socket close) while still
/// surfacing a genuine hang as a clean, named diagnostic.
const Duration _teardownTimeout = Duration(seconds: 15);

/// Runs [cleanup] but never lets it hang past [_teardownTimeout] or throw
/// out of a `tearDownAll` block — a slow or failing teardown must degrade to
/// a bounded, named diagnostic (`debugPrint`), never mask whatever the test
/// itself already reported. [label] identifies the cleanup in CI logs.
Future<void> _boundedTeardown(
  String label,
  Future<void> Function() cleanup,
) async {
  try {
    await cleanup().timeout(_teardownTimeout);
  } on Object catch (e) {
    debugPrint(
      '[e2e_combined:tearDownAll] $label did not complete within '
      '${_teardownTimeout.inSeconds}s (or threw): ${e.runtimeType}. '
      'Best-effort cleanup only — never rethrown.',
    );
  }
}

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
      await _boundedTeardown('carol.dispose', carol.dispose);
    }
    if (didInitBob) {
      await _boundedTeardown('bob.dispose', bob.dispose);
    }
    if (didInitPreSeed) {
      await _boundedTeardown(
        'TestUser.clearPreSeededIdentity',
        TestUser.clearPreSeededIdentity,
      );
    }
    if (didInitCtx) {
      await _boundedTeardown('ctx.relay.dispose', ctx.relay.dispose);
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
              ..._e2eProviderOverrides(),
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
        // Explicit, AWAITED live-sync engine teardown. Flag-on,
        // MapShell.initState started the engine, which occupies the
        // process-global Rust SESSION slot. Do NOT rely on the next test's
        // pumpWidget() disposing MapShell (fire-and-forget
        // `unawaited(_liveSync?.stop())`) to clear it: FE-2 never pumps
        // HavenApp, so without this the engine lingers in SESSION and the first
        // M11 scenario's start_session would otherwise have to replace a stale,
        // mid-teardown slot. stop() is idempotent, so it is safe even if the
        // engine never fully started (e.g. this scenario failed early).
        if (liveSyncEnabled) {
          try {
            final container = ProviderScope.containerOf(
              tester.element(find.byType(HavenApp)),
              listen: false,
            );
            await container.read(subscriptionServiceProvider).stop();
          } on Object catch (e) {
            debugPrint(
              '[e2e_combined] main-scenario engine teardown failed: '
              '${e.runtimeType}',
            );
          }
        }
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
      if (fe2DidInitDave) {
        await _boundedTeardown('fe2Dave.dispose', fe2Dave.dispose);
      }
      if (fe2DidInitAlice) {
        await _boundedTeardown('fe2Alice.dispose', fe2Alice.dispose);
      }
      if (fe2DidInitRelay) {
        await _boundedTeardown('fe2Relay.dispose', fe2Relay.dispose);
      }
    });

    boundedTestWidgets(
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

  // ===========================================================================
  // M11 — live-sync (persistent receive engine) scenarios.
  //
  // These prove the WIRED live path (Rust engine → FFI stream →
  // LiveEventRouter → providers → UI) that flipping `liveSyncEnabled`
  // activates. They only do real work under a `--dart-define=HAVEN_LIVE_SYNC=
  // true` build; each body self-guards with `if (!liveSyncEnabled) return;` so
  // the SAME source is inert (and green) on the default poll-path build —
  // including the plain `flutter test` unit run, which never compiles the flag
  // on.
  //
  // ONE live engine per process: the Rust live-sync SESSION is process-global,
  // so Alice (the pumped HavenApp) is the single live engine. Bob/Carol/Dave
  // stay in-process SyntheticUser peers that PUBLISH competing events via plain
  // FFI — they never run their own converging engine. Anything needing two
  // converging sessions is a haven-core Rust test, not one of these.
  //
  // Fully self-contained (own TestRelay + freshly-bootstrapped peers per test),
  // mirroring the FE-2 group above. KeyPackages are kind 30443 (addressable /
  // replaceable), so a peer seed reused across these tests always resolves to
  // its newest bootstrap's KP.
  //
  // Per-scenario test isolation: every scenario's `finally` calls
  // `_m11WipeAliceMlsState` right after `_m11StopEngine` (see its doc). Alice's
  // production circle-storage path is process-fixed (not per-identity), and no
  // M11 scenario ever has her LEAVE the circle(s) it creates, so without this
  // reset her circle count accumulates across the whole group — the confirmed
  // root cause of the CI-emulator-only B0/driver-2/c/e timeouts (a large
  // accumulated circle set makes every subsequent mid-session
  // `LiveSyncResubscriber` STOP+START span far longer than a fixed 20s/30s/45s
  // wait budget affords). The wipe clears only Alice's LOCAL storage — her
  // identity/seed (and the cached `_alicePubkeyHex()` scenarios `f`/`g` read)
  // is never touched.
  // ===========================================================================
  group('M11: live-sync (flag-on)', () {
    late TestRelay m11Relay;
    var m11DidInitRelay = false;

    setUpAll(() async {
      // Fresh probe socket for this group (isolated from the main scenario's
      // and FE-2's probes); the process-global bridge/keyring/relay override is
      // already installed by the outer setUpAll.
      m11Relay = await TestRelay.connect();
      m11DidInitRelay = true;
    });

    tearDownAll(() async {
      if (m11DidInitRelay) {
        await _boundedTeardown('m11Relay.dispose', m11Relay.dispose);
      }
    });

    // ------------------------------------------------------------------------
    // (a) Sub-second live delivery — a peer's location reaches Alice over the
    // stream well under the old 30 s poll floor (which is gated OFF flag-on).
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'a — a peer location arrives over the live stream well under the 30s '
      'poll floor',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob from every other M11
        // scenario's Bob (and from setUpAll's) on the same shared m11Relay
        // — see SyntheticUser.bob's doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 1);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);
          await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob],
            name: 'M11 a',
          );
          final bobCircle = await bob.acceptInvitationViaRelay(relay: m11Relay);

          // Give the debounced LiveSyncResubscriber time to STOP+START the
          // engine onto the new circle's #h before Bob publishes, so the
          // measured latency reflects a live push (strfry would otherwise
          // replay it on subscribe). A no-op if it already re-anchored.
          await _m11Settle(tester, generation);

          // Bob publishes AFTER the engine is subscribed; start the clock at
          // the publish. Under live-sync the 30 s receive timer is gated OFF,
          // so any delivery is over LiveSyncFfi.liveEvents().
          await bob.publishLocation(
            circle: bobCircle,
            latitude: bobFakeLatitude,
            longitude: bobFakeLongitude,
            relay: m11Relay,
          );
          final latency = await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: bob.pubkeyHex,
          );
          debugPrint(
            '[M11:a] live location surfaced in ${latency.inMilliseconds}ms '
            '(engine stream; poller gated off)',
          );
          expect(
            latency,
            lessThan(const Duration(seconds: 20)),
            reason:
                '[M11:a] the location took ${latency.inMilliseconds}ms to '
                'reach memberLocationsProvider. Under live-sync the 30s poll '
                'is OFF, so any delivery is the live stream — it must land '
                'well under the old 30s floor.',
          );

          // Correct coordinates (not merely presence) — guards a decrypt-but-
          // corrupt regression on the stream path.
          final locs = await container.read(memberLocationsProvider.future);
          _assertMemberLocationCoordinates(
            label: 'M11:a alice <- bob (live stream)',
            locs: locs,
            senderPubkeyHex: bob.pubkeyHex,
            expectedLatitude: bobFakeLatitude,
            expectedLongitude: bobFakeLongitude,
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (B0) Create-then-live WITHOUT relaunch (GO-MUST): a circle created mid-
    // session receives live locations because LiveSyncResubscriber re-anchors
    // the engine — the engine started (initState) BEFORE this circle existed.
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'B0 — a circle created mid-session receives live locations without a '
      'relaunch',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Carol — see SyntheticUser
        // .bob's doc.
        final carol = await SyntheticUser.carol(m11Relay, seedOffset: 2);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);

          // The engine already started (initState → _startLiveSync) with
          // whatever circles existed at mount. Snapshot that set: the circle we
          // create next is NOT in it, so receiving a location for it proves the
          // mid-session re-subscribe, not a start-time subscription.
          final atStart = await container.read(circlesProvider.future);
          final atStartIds = <String>{};
          for (final c in atStart) {
            atStartIds.add(_hexLower(Uint8List.fromList(c.nostrGroupId)));
          }

          final circle = await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[carol],
            name: 'M11 B0',
          );
          expect(
            atStartIds.contains(_hexLower(circle.nostrGroupId)),
            isFalse,
            reason:
                '[M11:B0] the new circle must not have existed at engine start '
                '— otherwise this would prove a start-time subscription, not '
                'the mid-session re-subscribe.',
          );

          final carolCircle =
              await carol.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);
          await carol.publishLocation(
            circle: carolCircle,
            latitude: carolFakeLatitude,
            longitude: carolFakeLongitude,
            relay: m11Relay,
          );
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: carol.pubkeyHex,
          );
          debugPrint(
            '[M11:B0] received a live location for a mid-session circle — '
            'LiveSyncResubscriber re-anchored the engine (no relaunch).',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('carol dispose (teardown)', carol.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (H1) Membership op under concurrent Location traffic (GO-MUST): Alice
    // removes a member while a peer floods Location kind:445s into the same
    // circle. The receiver-side liveness gate must let the removal CONVERGE
    // (roster drops the member, epoch advances) and never surface notApplied /
    // "failed to remove".
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'H1 — remove-member converges under concurrent Location noise (no '
      'notApplied)',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob/Carol — see
        // SyntheticUser.bob's doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 3);
        final carol = await SyntheticUser.carol(m11Relay, seedOffset: 3);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);
          final circle = await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob, carol],
            name: 'M11 H1',
          );
          await bob.acceptInvitationViaRelay(relay: m11Relay);
          final carolCircle =
              await carol.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);

          final mlsGroupId = circle.mlsGroupId.toList();
          final epochBefore = await _aliceEpochForTest(tester, mlsGroupId);

          // Carol floods Location events across the ~8 s settle window so a
          // Location competitor is in-flight while the removal converges. Kept
          // unawaited so it overlaps the awaited removeMember below; an
          // individual publish failure (an epoch Carol no longer holds after
          // the commit) is swallowed — the assertion is on the removal
          // converging, not on the noise landing.
          Future<void> runNoise() async {
            for (var i = 0; i < 8; i++) {
              try {
                await carol.publishLocation(
                  circle: carolCircle,
                  latitude: carolFakeLatitude,
                  longitude: carolFakeLongitude,
                  relay: m11Relay,
                );
              } on Object catch (e) {
                debugPrint('[M11:H1] noise publish skipped: ${e.runtimeType}');
              }
              await Future<void>.delayed(const Duration(milliseconds: 1000));
            }
          }

          final noise = runNoise();

          // Remove Bob through the production converging path (flag-on routes
          // removeMember via stage_remove_members_converging + settle window +
          // converge_after_window). This MUST NOT throw notApplied.
          await container.read(circleServiceProvider).removeMember(
                mlsGroupId: mlsGroupId,
                memberPubkeyHex: bob.pubkeyHex,
              );
          await noise; // drain the noise loop (its errors are swallowed above)

          final roster = await _m11AliceRoster(container, mlsGroupId);
          expect(
            roster.contains(bob.pubkeyHex.toLowerCase()),
            isFalse,
            reason:
                '[M11:H1] Bob must be gone from the roster after a converged '
                'remove under Location noise; the liveness gate failed to '
                'converge (roster size ${roster.length}).',
          );
          expect(
            roster.contains(_alicePubkeyHex().toLowerCase()),
            isTrue,
            reason: '[M11:H1] Alice must remain in her own roster.',
          );
          final epochAfter = await _aliceEpochForTest(tester, mlsGroupId);
          expect(
            epochAfter,
            greaterThan(epochBefore),
            reason:
                '[M11:H1] the MLS epoch must advance past $epochBefore after '
                'the remove converged; got $epochAfter.',
          );
          debugPrint(
            '[M11:H1] remove converged under Location noise: epoch '
            '$epochBefore->$epochAfter, roster=${roster.length}.',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('carol dispose (teardown)', carol.dispose);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (driver-2) Leaver backstop live path (GO-MUST, REV-1): a non-admin peer
    // leaves; Alice's live engine converges the removal so the departed peer
    // disappears from her roster within a bounded time (no manual drain).
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'driver-2 — a non-admin leave converges out of the roster live',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob — see SyntheticUser.bob's
        // doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 4);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);
          final circle = await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob],
            name: 'M11 driver-2',
          );
          final bobCircle = await bob.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);

          final mlsGroupId = circle.mlsGroupId.toList();
          final before = await _m11AliceRoster(container, mlsGroupId);
          expect(
            before.contains(bob.pubkeyHex.toLowerCase()),
            isTrue,
            reason: '[M11:driver-2] Bob must be a member before he leaves.',
          );

          // Bob leaves as a non-admin (publishes a SelfRemove). Alice's engine
          // must converge it (auto-commit / REV-1 backstop) and evict Bob.
          await bob.leaveAsNonAdmin(circle: bobCircle, relay: m11Relay);
          await _m11PumpUntilRosterDrops(
            tester,
            container,
            generation,
            mlsGroupId: mlsGroupId,
            gonePubkeyHex: bob.pubkeyHex,
          );
          debugPrint(
            '[M11:driver-2] the live engine converged the non-admin leave — '
            'Bob left the roster without a manual drain.',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (f) NIP-59 back-dated Welcome via the inbox 7-day lookback: a peer sends
    // Alice a gift-wrapped Welcome (kind 1059, back-dated created_at); it
    // surfaces in pendingInvitations over the engine's inbox #p stream (the
    // invitation poller is gated OFF flag-on).
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'f — a back-dated gift-wrapped Welcome surfaces via the inbox stream',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob — see SyntheticUser.bob's
        // doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 5);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);

          // Alice's KeyPackage must be on the relay (published by
          // keyPackagePublisherProvider on mount) so Bob can invite her.
          await waitForKeyPackage(
            relay: m11Relay,
            authorPubkeyHex: _alicePubkeyHex(),
          );
          final relayManager = await RelayManagerFfi.newInstance();
          final aliceKp = await relayManager.fetchMemberKeypackage(
            pubkey: _alicePubkeyHex(),
          );
          if (aliceKp == null) {
            throw StateError(
              '[M11:f] fetchMemberKeypackage returned null for Alice — her KP '
              'never reached the relay.',
            );
          }

          // Bob (a SyntheticUser, no engine) creates a circle inviting Alice;
          // the resulting Welcome carries the NIP-59 back-dated (±48 h)
          // created_at the FFI stamps.
          final bobSecret = await bob.user.getSecretBytes();
          final CircleCreationResultFfi creation;
          try {
            creation = await bob.user.circleManager.createCircle(
              identitySecretBytes: bobSecret,
              members: <MemberKeyPackageFfi>[aliceKp],
              name: 'M11 f Circle',
              circleType: 'location_sharing',
              relays: <String>[m11Relay.url],
              creatorFallbackRelays: <String>[m11Relay.url],
            );
          } finally {
            for (var i = 0; i < bobSecret.length; i++) {
              bobSecret[i] = 0;
            }
          }
          final aliceWelcome = creation.welcomeEvents.firstWhere(
            (e) =>
                e.recipientPubkey.toLowerCase() ==
                _alicePubkeyHex().toLowerCase(),
            orElse: () => throw StateError(
              '[M11:f] Bob createCircle produced no Welcome for Alice.',
            ),
          );
          final (ok, msg) =
              await m11Relay.publishAndAwaitOk(aliceWelcome.eventJson);
          if (!ok) {
            throw StateError('[M11:f] relay rejected the Welcome: $msg');
          }

          // The engine's inbox plane (#p=Alice, 7-day lookback) delivers the
          // back-dated wrap → processGiftWrappedInvitation → invalidate
          // pendingInvitationsProvider. Poll until it surfaces.
          await _m11PumpUntilInvitation(
            tester,
            container,
            generation,
            mlsGroupId: creation.circle.mlsGroupId.toList(),
          );
          debugPrint(
            '[M11:f] a back-dated Welcome surfaced in pendingInvitations via '
            'the inbox stream (poller off).',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (b) and (c) — REMOVED (Dark Matter DM-4b).
    //
    // (b) "Concurrent-commit convergence (one-sided proxy)" raced Alice's
    // REAL converging `removeMember` against a genuine competing commit
    // manufactured via `SyntheticUser.stageAndFinalizeSelfUpdate`, then
    // asserted on Haven's OWN hand-rolled settle-window/MIP-03-winner
    // convergence machinery (`stage_remove_members_converging`,
    // `converge_after_window`, `settleWindowSecs`). That whole Dart-side
    // settle-window orchestration is deleted — the Dark Matter engine now
    // owns publish-before-apply AND commit-ordering/convergence internally
    // via typed `PendingStateRef` tokens, with no Haven-authored settle
    // window, MIP-03 order key, or native-rollback proxy left to exercise.
    // `stageAndFinalizeSelfUpdate` itself has no FFI equivalent (`self_update`
    // is deleted — MIP-02/03 rotation is engine-internal; see
    // `self_update_provider.dart`), so there is no way to manufacture this
    // race from Dart any more.
    //
    // (c) "Unprocessable-does-not-advance / does-not-bury (PSI-7)" asserted
    // on the OLD MDK's sticky-`Unprocessable`/`PreviouslyFailed` poison
    // cache (`ProcessedMessageState::Failed`, keyed permanently by Nostr
    // event id, un-poisoned only by an `is_better_candidate` rollback) —
    // exactly the bug class the Dark Matter engine's stored convergence
    // buffer (`MessageState::{Retryable,PeelDeferred,…}` +
    // `advance_convergence`) is designed to remove (migration plan §2.1).
    // Under the new engine a future-epoch event is durably buffered and
    // RE-SURFACED once the gap fills — the opposite of what this test
    // asserted — and it also depended on `stageAndFinalizeSelfUpdate` to
    // manufacture the out-of-order pair.
    //
    // Both scenarios' underlying protocol property — real out-of-order /
    // concurrent-commit convergence — is NOT dropped: the migration plan
    // requires it be kept and re-expressed as a Rust-side black-box e2e
    // over the new engine (`live_sync_out_of_order_commit_e2e.rs`, plan
    // §5.7, security F2), which is haven-core's (not this Dart harness's)
    // responsibility and lives outside this file's scope.
    // ------------------------------------------------------------------------

    // ------------------------------------------------------------------------
    // (d) Cursor-survives-restart (stop+restart the SAME production engine):
    // Bob publishes a location while Alice's engine is STOPPED; restarting
    // it re-anchors `since` from the SQLCipher-persisted per-circle cursor
    // and delivers the missed location — proving the persisted cursor
    // drives recovery, not an in-memory value.
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'd — a location published while the engine is stopped surfaces after '
      'the engine restarts (cursor persisted, not lost)',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob — see SyntheticUser.bob's
        // doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 8);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);
          await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob],
            name: 'M11 d',
          );
          final bobCircle =
              await bob.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);

          // Sanity: the engine is genuinely live before "stopping" it.
          await bob.publishLocation(
            circle: bobCircle,
            latitude: bobFakeLatitude,
            longitude: bobFakeLongitude,
            relay: m11Relay,
          );
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: bob.pubkeyHex,
          );

          // Stop the production engine — nothing consumes events while it
          // is down.
          await container.read(subscriptionServiceProvider).stop();
          expect(
            container.read(subscriptionServiceProvider).isRunning,
            isFalse,
          );

          // The missed location MUST carry a strictly-LATER `created_at` second
          // than the pre-stop sanity location above. The member-location cache is
          // timestamp-wins with a STRICT `isAfter`, one slot per sender
          // (location_sharing_service.dart ~605), so a missed location that
          // shares the sanity location's whole second is DISCARDED as not-newer
          // and never surfaces — the scenario would then time out even though the
          // engine redelivered it. Earlier runs incidentally spaced the two
          // publishes apart because the engine `stop()` hung for ~25s; now that
          // stop() completes in ~1ms they would otherwise land in the SAME
          // second. This short real-time gap restores the realistic spacing this
          // scenario models (a peer whose position changes over time) and makes
          // the redelivery assertion deterministic.
          await Future<void>.delayed(const Duration(seconds: 2));

          // Bob publishes the "missed" location while Alice's engine is
          // down; it just lands on strfry.
          const missedLat = bobFakeLatitude + 0.01;
          const missedLon = bobFakeLongitude + 0.01;
          await bob.publishLocation(
            circle: bobCircle,
            latitude: missedLat,
            longitude: missedLon,
            relay: m11Relay,
          );
          await Future<void>.delayed(const Duration(seconds: 1));

          // Restart — re-subscribes with `since` re-anchored from the
          // SQLCipher-persisted cursor, so the missed location redelivers.
          await _m11ForceResubscribe(container);

          // Coordinate-aware (FIND-D1 fix): the pre-stop sanity publish
          // above already cached an entry for Bob, so a bare presence check
          // would return immediately on that STALE entry without ever
          // waiting for the missed location to actually redeliver. Waiting
          // on the MISSED coordinates specifically makes this a genuine
          // (non-vacuous) wait for the restart-recovered delivery.
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: bob.pubkeyHex,
            timeout: const Duration(seconds: 30),
            expectedLatitude: missedLat,
            expectedLongitude: missedLon,
          );
          final locs = await container.read(memberLocationsProvider.future);
          _assertMemberLocationCoordinates(
            label: 'M11:d cursor-survives-restart',
            locs: locs,
            senderPubkeyHex: bob.pubkeyHex,
            expectedLatitude: missedLat,
            expectedLongitude: missedLon,
          );
          debugPrint(
            '[M11:d] the missed location surfaced after the engine '
            'restarted — the cursor persisted through the stop/start cycle.',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (e) Many-circle multiplexed delivery: Alice is in two circles at once;
    // both peers publish while she never restarts her ONE engine session —
    // proves multiplexed delivery, not per-circle poll timers.
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'e — Alice in two circles receives live locations from both via ONE '
      'engine session',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob/Carol — see
        // SyntheticUser.bob's doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 9);
        final carol = await SyntheticUser.carol(m11Relay, seedOffset: 9);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);

          final circle1 = await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob],
            name: 'M11 e (Bob)',
          );
          final bobCircle =
              await bob.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);

          final circle2 = await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[carol],
            name: 'M11 e (Carol)',
          );
          final carolCircle =
              await carol.acceptInvitationViaRelay(relay: m11Relay);
          // ONE settle covers both circles — the same engine re-subscribes
          // onto the union of accepted circles (LiveSyncResubscriber).
          await _m11Settle(tester, generation);

          await bob.publishLocation(
            circle: bobCircle,
            latitude: bobFakeLatitude,
            longitude: bobFakeLongitude,
            relay: m11Relay,
          );
          await carol.publishLocation(
            circle: carolCircle,
            latitude: carolFakeLatitude,
            longitude: carolFakeLongitude,
            relay: m11Relay,
          );

          // memberLocationsProvider is scoped to the SELECTED circle; the
          // underlying cache is per-circle and selection-independent, so
          // selecting each circle in turn surfaces its own delivery.
          container.read(selectedCircleIdProvider.notifier).state =
              circle1.mlsGroupId.toList();
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: bob.pubkeyHex,
          );

          container.read(selectedCircleIdProvider.notifier).state =
              circle2.mlsGroupId.toList();
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: carol.pubkeyHex,
          );

          debugPrint(
            '[M11:e] Alice received locations from BOTH circles via one '
            'engine session (no per-circle poll timers, no engine restart '
            'between the two deliveries).',
          );
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('carol dispose (teardown)', carol.dispose);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );

    // ------------------------------------------------------------------------
    // (g) Flag-flip dedup reconciliation: redeliver the SAME location and
    // the SAME gift-wrapped Welcome twice via a forced resubscribe; assert
    // no duplicate marker / invitation. Proves the AS-BUILT idempotency
    // (pubkey-keyed timestamp-wins cache merge + `is_gift_wrap_processed`
    // dedup) — NOT a `_seenEventIds` set (there is none on this path).
    // ------------------------------------------------------------------------
    _m11ScenarioTestWidgets(
      'g — redelivering the SAME location and the SAME welcome twice '
      'produces no duplicates',
      (tester, generation) async {
        if (!liveSyncEnabled) return;
        // seedOffset decouples this scenario's Bob — see SyntheticUser.bob's
        // doc.
        final bob = await SyntheticUser.bob(m11Relay, seedOffset: 10);
        ProviderContainer? container;
        try {
          container = await _m11PumpAliceLiveEngine(tester, generation);

          // ---- location dedup ----
          await _m11AliceCreatesCircle(
            tester: tester,
            container: container,
            relay: m11Relay,
            invitees: <SyntheticUser>[bob],
            name: 'M11 g',
          );
          final bobCircle =
              await bob.acceptInvitationViaRelay(relay: m11Relay);
          await _m11Settle(tester, generation);

          await bob.publishLocation(
            circle: bobCircle,
            latitude: bobFakeLatitude,
            longitude: bobFakeLongitude,
            relay: m11Relay,
          );
          await _m11AwaitLiveLocation(
            tester,
            container,
            generation,
            senderPubkeyHex: bob.pubkeyHex,
          );
          var locs = await container.read(memberLocationsProvider.future);
          expect(
            locs
                .where(
                  (l) =>
                      l.pubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
                )
                .length,
            1,
          );

          // Force a resubscribe — strfry's `since` is inclusive, so the
          // group cursor (advanced to this event's own created_at)
          // redelivers it.
          await _m11ForceResubscribe(container);
          await _m11Settle(tester, generation);
          container.invalidate(memberLocationsProvider);
          locs = await container.read(memberLocationsProvider.future);
          expect(
            locs
                .where(
                  (l) =>
                      l.pubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
                )
                .length,
            1,
            reason: '[M11:g] the SAME location redelivered must not '
                "produce a second marker — location_sharing_service.dart's "
                'timestamp-wins, pubkey-keyed cache merge (a Map, not a '
                'List) is structurally idempotent; NOT a _seenEventIds set.',
          );
          _assertMemberLocationCoordinates(
            label: 'M11:g location dedup',
            locs: locs,
            senderPubkeyHex: bob.pubkeyHex,
            expectedLatitude: bobFakeLatitude,
            expectedLongitude: bobFakeLongitude,
          );

          // ---- welcome dedup ----
          await waitForKeyPackage(
            relay: m11Relay,
            authorPubkeyHex: _alicePubkeyHex(),
          );
          final relayManager = await RelayManagerFfi.newInstance();
          final aliceKp = await relayManager.fetchMemberKeypackage(
            pubkey: _alicePubkeyHex(),
          );
          if (aliceKp == null) {
            throw StateError(
              '[M11:g] fetchMemberKeypackage returned null for Alice.',
            );
          }
          final bobSecret = await bob.user.getSecretBytes();
          final CircleCreationResultFfi creation;
          try {
            creation = await bob.user.circleManager.createCircle(
              identitySecretBytes: bobSecret,
              members: <MemberKeyPackageFfi>[aliceKp],
              name: 'M11 g Circle',
              circleType: 'location_sharing',
              relays: <String>[m11Relay.url],
              creatorFallbackRelays: <String>[m11Relay.url],
            );
          } finally {
            for (var i = 0; i < bobSecret.length; i++) {
              bobSecret[i] = 0;
            }
          }
          final aliceWelcome = creation.welcomeEvents.firstWhere(
            (e) =>
                e.recipientPubkey.toLowerCase() ==
                _alicePubkeyHex().toLowerCase(),
            orElse: () => throw StateError(
              '[M11:g] Bob createCircle produced no Welcome for Alice.',
            ),
          );
          final (ok, msg) =
              await m11Relay.publishAndAwaitOk(aliceWelcome.eventJson);
          if (!ok) {
            throw StateError('[M11:g] relay rejected the Welcome: $msg');
          }

          await _m11PumpUntilInvitation(
            tester,
            container,
            generation,
            mlsGroupId: creation.circle.mlsGroupId.toList(),
          );
          var invitations = await container.read(
            pendingInvitationsProvider.future,
          );
          expect(
            invitations
                .where(
                  (i) => listEquals(i.mlsGroupId, creation.circle.mlsGroupId),
                )
                .length,
            1,
          );

          // Force the SAME gift-wrap to redeliver (resubscribe; the inbox
          // cursor advanced to THIS wrap's timestamp via
          // advanceInboxCursorToWrapSecs, which is inclusive on re-REQ).
          await _m11ForceResubscribe(container);
          await _m11Settle(tester, generation);
          container.invalidate(pendingInvitationsProvider);
          invitations = await container.read(
            pendingInvitationsProvider.future,
          );
          expect(
            invitations
                .where(
                  (i) => listEquals(i.mlsGroupId, creation.circle.mlsGroupId),
                )
                .length,
            1,
            reason: '[M11:g] the SAME gift-wrap redelivered must not '
                'produce a second pendingInvitation — '
                'processGiftWrappedInvitation returns null the second time, '
                "backed by haven-core's is_gift_wrap_processed dedup.",
          );
          debugPrint('[M11:g] location + welcome redelivery both idempotent.');
        } finally {
          await _m11StopEngine(container, generation);
          // Test-isolation reset — see _m11WipeAliceMlsState's doc: keeps
          // Alice's circle count from accumulating across M11 scenarios.
          await _m11WipeAliceMlsState(container, generation);
          // Explicitly tear down this scenario's widget tree/ProviderScope —
          // scenarios a-f are only incidentally torn down by the NEXT
          // scenario's `pumpWidget`, which leaves the LAST scenario ('g')
          // leaking its maintenance timer (and the rest of its provider
          // tree) into `tearDownAll`. Run this AFTER the engine stop so the
          // dispose ordering is engine-first, widget-tree-second.
          await _m11TeardownWidgetTree(tester, generation);
          await _m11Bounded('bob dispose (teardown)', bob.dispose);
        }
      },
    );
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
  await tapWhenHittable(tester, find.byKey(WidgetKeys.circlesCreateCta));
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

  await tapWhenHittable(tester, find.byKey(WidgetKeys.createCircleContinue));
  await pumpUntilFound(
    tester,
    find.byType(NameCirclePage),
    description: 'NameCirclePage after Continue tap',
  );
  await tester.enterText(
    find.byKey(WidgetKeys.circleNameInput),
    _circleName,
  );
  await tapWhenHittable(tester, find.byKey(WidgetKeys.createCircleConfirm));
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
  // Not awaited until later (after driving the UI + pumpUntilGone below), so
  // if its OWN internal deadline elapses first, Dart would otherwise report
  // it as an unhandled zone error RIGHT NOW — ending the test mid-flight
  // while pumpUntilGone is still suspended, orphaning it as a zombie that
  // keeps running past "test completion" (colliding with later tests' shared
  // engine SESSION / WidgetTester state — the same class of hazard the M11
  // generation-token guard fixes for the M11 group). `.ignore()` only
  // silences that premature report; the real completion (value or rethrow)
  // still surfaces normally at the `await` below.
  final carolGiftWrapFuture =
      ctx.relay.firstWhere(
        filter: <String, dynamic>{
          'kinds': const <int>[1059],
          '#p': <String>[carol.pubkeyHex],
          'limit': 10,
        },
        matcher: (event) => !preAddCarolWrapIds.contains(event.id),
        timeout: _giftWrapDeadline,
      )..ignore();
  // The kind-445 stream for this group is NOT commits-only: location updates
  // are also kind-445 with the same #h tag, so one can land inside this
  // `since` window and race the Add commit. Location updates carry a NIP-40
  // `expiration` tag; an MLS commit MUST NOT (a NIP-40 relay stops serving
  // expired events, which would break epoch catch-up for late/offline peers —
  // see haven-core/SECURITY.md and the Rust
  // `*_evolution_event_has_no_expiration_tag` tests). Select the Add commit by
  // that protocol invariant so a racing location update is never mistaken for
  // it.
  // See carolGiftWrapFuture's `.ignore()` doc above — same premature-
  // unhandled-error hazard, same fix.
  final addCommitFuture =
      ctx.relay.firstWhere(
        filter: <String, dynamic>{
          'kinds': const <int>[445],
          '#h': <String>[nostrGroupIdHex],
          'since': sinceSecs,
          'limit': 10,
        },
        matcher: (event) => event.tag('expiration') == null,
        timeout: _giftWrapDeadline,
      )..ignore();

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
  await tapWhenHittable(tester, detailsButton);
  // Modal opens on top of MapShell — wait for the "Add member" CTA to be
  // findable rather than pumpAndSettle (MapShell's periodic timers keep
  // the frame queue non-empty even while the modal is up).
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.addMemberCta),
    description: 'addMemberCta after tapping circle-details info button',
  );

  // Tap "Add member" and wait for AddMemberPage to mount.
  await tapWhenHittable(tester, find.byKey(WidgetKeys.addMemberCta));
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
  await tapWhenHittable(tester, find.byKey(WidgetKeys.addMemberConfirm));
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
  // Bounded — see `_riverpodPollerReadTimeout`'s doc. This is a one-shot
  // call with no `_pollUntil` wrapper to fall back on, so an orphaned read
  // (MapShell's own `_guardedPublish` timer/motion-trigger invalidating
  // `locationPublisherProvider` concurrently) would otherwise hang far
  // past this file's other 60 s convergence budgets — and could resume
  // after this test method returns, tripping `!inTest` in the NEXT test.
  // Fail fast with an actionable message instead.
  final publishedCount = await container
      .read(locationPublisherProvider.future)
      .timeout(
        _riverpodPollerReadTimeout,
        onTimeout: () => throw StateError(
          '[e2e_combined:alice] PHASE 3b: locationPublisherProvider read '
          'timed out after ${_riverpodPollerReadTimeout.inSeconds}s — '
          'likely a concurrent background-poller invalidate orphaned this '
          "read's Riverpod future.",
        ),
      );
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
  // Bounded — see `_riverpodPollerReadTimeout`'s doc. This is a one-shot
  // call with no `_pollUntil` wrapper to fall back on, so an orphaned read
  // (MapShell's own `_guardedPublish` timer/motion-trigger invalidating
  // `locationPublisherProvider` concurrently) would otherwise hang far
  // past this file's other 60 s convergence budgets — and could resume
  // after this test method returns, tripping `!inTest` in the NEXT test.
  // Fail fast with an actionable message instead.
  final published = await container
      .read(locationPublisherProvider.future)
      .timeout(
        _riverpodPollerReadTimeout,
        onTimeout: () => throw StateError(
          '[e2e_combined:alice] locationPublisherProvider read timed out '
          'after ${_riverpodPollerReadTimeout.inSeconds}s — likely a '
          "concurrent background-poller invalidate orphaned this read's "
          'Riverpod future.',
        ),
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
  // in `memberLocationsProvider`.
  //
  // FE-3 (de-flake, round 1): an earlier version of this probe invalidated
  // AND `await`-ed all three of `locationPublisherProvider`,
  // `evolutionPollerProvider`, and `memberLocationsProvider` on every
  // attempt (mirroring MapShell's on-resume handler). That is unsafe here:
  // `JoinWatcherNotifier._runTick` invalidates + reads
  // `evolutionPollerProvider` (and, unconditionally, `memberLocationsProvider`)
  // in the BACKGROUND every 4-8 s for the ~150-240 s admin-burst window that
  // starts the moment Alice creates a circle — comfortably longer than this
  // whole scenario — and `MapShell`'s own timers do the same on their own
  // cadence. If one of those background invalidations lands between the
  // probe's own `invalidate()` and its own `.future` read of the SAME
  // provider, Riverpod discards the stale build the read captured a
  // reference to: the `Future` being awaited can then never resolve (or
  // resolves long after that attempt "should" have finished). A bare
  // `await` on that stale Future hung the ENTIRE 60 s `_peerConvergenceBudget`
  // on its first attempt (CI run 29360479997) even though the underlying
  // data had already converged — and the abandoned `async` frame later
  // resumed past `_pollUntil`'s own timeout, calling `tester.pump()` from a
  // torn-down test and tripping `!inTest` in the NEXT `testWidgets` block.
  //
  // Round 1 stopped forcing `locationPublisherProvider` (Step 1 above
  // already invalidated + awaited it once and asserted `published >= 1` —
  // Alice's own location is already on the relay, so republishing again
  // every 3 s here was pure redundant traffic) and `evolutionPollerProvider`
  // (not needed for THIS convergence: `memberLocationsProvider`'s own
  // non-live-sync build calls `fetchMemberLocations` directly, its own
  // independent kind-445 relay round trip, with no dependency on
  // `evolutionPollerProvider` having run first), then bounded the
  // remaining `memberLocationsProvider.future` read with a short
  // `.timeout`. That closed the hang/cascade, but a residual race
  // remained: `memberLocationsProvider` is ALSO invalidated
  // unconditionally by JoinWatcher's tick (and MapShell's 30 s receive
  // timer), so OUR OWN `invalidate()` + `.future` read of it was still
  // exposed to the exact same stale-build-discard race described above —
  // merely bounded to 10 s instead of unbounded, so an unlucky run of
  // orphaned attempts could still intermittently eat into the 60 s budget.
  //
  // FE-3 (de-flake, round 2): removed the LAST orphanable `await` from
  // this probe entirely. Rather than forcing our own rebuild and awaiting
  // it, we read the provider's CURRENT `AsyncValue` synchronously —
  // `container.read(memberLocationsProvider).valueOrNull` — which cannot
  // be orphaned because there is no Future being raced against anything;
  // `container.read(provider)` (no `.future`) returns immediately. Two
  // production facts make this safe and non-lossy:
  //   1. `map_page.dart` has a live `ref.watch(memberLocationsProvider)` for
  //      the whole scenario (it renders the location markers), so Riverpod
  //      eagerly rebuilds the provider on every invalidate rather than
  //      waiting for a pull-`read()` — JoinWatcher's 4-8 s admin-burst tick
  //      and MapShell's 30 s/60 s timers alone keep it fresh throughout
  //      this phase without this probe invalidating anything itself.
  //   2. Riverpod 2.x's seamless `AsyncValue` transition
  //      (`AsyncTransition.asyncTransition` → `copyWithPrevious`,
  //      `riverpod-2.6.1/lib/src/common.dart` and
  //      `async_notifier/base.dart`'s `_onLoading`/`onData`) means that the
  //      instant a rebuild starts, the new `AsyncLoading<T>` carries over
  //      the PREVIOUS build's `value`/`hasValue`. So `valueOrNull` keeps
  //      returning the last successfully fetched list throughout any
  //      number of concurrent background invalidate/rebuild cycles — it
  //      only ever advances forward to a NEWER successful fetch, never
  //      regresses to null once the first fetch has landed. (This is the
  //      same pattern `circles_bottom_sheet.dart` already uses:
  //      `ref.watch(memberLocationsProvider).valueOrNull ?? ...`.)
  // The three short `tester.pump()`s below give the app's ambient
  // background pollers a chance to flush a pending rebuild through before
  // we check; if a fetch is still genuinely in flight (or has never
  // completed yet), `valueOrNull` falls back to `aliceLastLocs` (empty on
  // the very first attempt) so this attempt reports "not yet converged"
  // rather than crashing on a null — `_pollUntil`'s 3 s interval then
  // retries. No coverage is lost: the convergence gate (`missing.isEmpty`)
  // and the coordinate asserts after the loop are unchanged, and the
  // underlying fetch pipeline keeps running exactly as before — only
  // driven entirely by the app's own background pollers now, with zero
  // test-owned awaits left in this probe to orphan.
  await _pollUntil<Set<String>>(
    describe:
        'alice: memberLocationsProvider convergence — expected '
        '${expectedPeerSet.length} peers '
        '(${expectedPeerSet.map(_redactPk).join(", ")})',
    probe: () async {
      // Three short pumps cover any rebuild listeners the app's own
      // background pollers (JoinWatcher / MapShell timers) scheduled
      // without depending on the global frame queue draining (MapShell's
      // periodic timers keep it perpetually non-empty under
      // IntegrationTestWidgetsFlutterBinding).
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      // Deliberately NOT `invalidate()` + `await ... .future` — see the
      // doc above. This synchronous read of the CURRENT `AsyncValue`
      // cannot be orphaned by a concurrent background invalidate.
      final locs =
          container.read(memberLocationsProvider).valueOrNull ??
          aliceLastLocs;

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
    // Bound each probe by the remaining budget. A bare `await probe()`
    // lets a single non-completing probe Future block forever — the loop
    // never returns to the deadline check, so `budget` is silently
    // defeated (the root cause of a 9-minute hang + cross-test cascade).
    // `.timeout` converts any stuck probe into a fast, attributed failure.
    final remaining = deadline.difference(DateTime.now());
    final T result;
    try {
      result = await probe().timeout(remaining);
    } on TimeoutException {
      break;
    }
    lastResult = result;
    if (satisfied(result)) return result;
    await Future<void>.delayed(interval);
  }
  throw StateError(
    '[e2e_combined] convergence timed out after ${budget.inSeconds}s: '
    '$describe (last result: '
    '${lastResult ?? "<no probe completed within budget>"})',
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
  await tapWhenHittable(tester, detailsButton);
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
  await tapWhenHittable(tester, leaveCta);
  // Wait for the confirmation dialog's keyed "Leave" button. Keying
  // it disambiguates from the dialog title "Leave Circle" without a
  // brittle widgetWithText(TextButton, 'Leave') text match.
  await pumpUntilFound(
    tester,
    find.byKey(WidgetKeys.leaveCircleConfirm),
    description: 'Leave confirmation dialog after tapping Leave Circle',
  );

  await tapWhenHittable(tester, find.byKey(WidgetKeys.leaveCircleConfirm));

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
/// ## Alice's leave is a variable-length burst, not a fixed count
///
/// An earlier version of this driver assumed Alice's leave publishes
/// EXACTLY three kind-445 events (AdminHandoff → SelfDemote →
/// SelfRemove) and fixed-index-sliced the arrival-ordered inbox
/// (`take(3)` / `skip(3)`). In production this burst is variable in
/// length: AdminHandoff, SelfDemote, the SelfRemove proposal PLUS a
/// bounded number of re-issues from Alice's leaver-backstop
/// "poll-own-removal → re-issue" loop (`nostr_circle_service.dart`),
/// her own mid-leave location, and avatar epoch-reshare chunks
/// triggered by the epoch change — all on the same kind-445 `#h` tag
/// the inbox subscribes to. Fixed-index slicing silently
/// mis-attributes a stray event as "the SelfRemove" (or vice versa),
/// which can starve the elected winner of the real proposal entirely
/// while the loser becomes the sole committer — winner/loser INVERTED
/// (this concretely happened: the winner stuck at 3 members while the
/// loser alone advanced to 2, a deterministic `bobMembers=3
/// carolMembers=2` residual failure). This driver is therefore
/// CONTENT-DRIVEN: it re-applies the (growing) arrival-ordered buffer
/// and polls each peer's own MDK-reported state to decide when to
/// stop, and never assumes a fixed event count.
///
/// ## The fix: elect ONE committer, the loser adopts it
///
/// This is the exact shape the in-repo Rust test
/// `concurrent_admin_remove_member_converges_after_clear_pending`
/// (`haven-core/src/circle/manager.rs`) proves converges:
///   1. Elect the winner deterministically as the `select_successor`
///      result — the lex-smallest of `{bob, carol}` (which is also the
///      new admin after the handoff). No MLS-internal state read needed.
///   2. The WINNER re-applies the growing arrival-ordered buffer with
///      `finalizeAutoCommit: true` until its OWN MDK state shows Alice
///      removed. It auto-commits the FIRST valid SelfRemove it
///      processes — later re-issues / the location / avatar chunks
///      target a stale epoch once Alice is gone and are absorbed
///      harmlessly as decrypt failures — and publishes exactly ONE
///      commit, `C_winner`. Its event id is captured directly from the
///      publish (`ApplyEventsSummary.publishedCommitEventIds`), not
///      inferred positionally from the buffer.
///   3. The LOSER re-applies the same growing buffer with
///      `finalizeAutoCommit: false`, which stages but WITHHOLDS its own
///      candidate SelfRemove commit and stops processing the rest of
///      that call the instant it does so (see `applyArrivalOrdered`'s
///      doc — MDK cannot apply further group events while an
///      uncommitted pending commit is outstanding). Once staged, the
///      loser `clearPendingCommit`s it, then forward-applies
///      `C_winner` directly — found on the shared inbox by its
///      captured id, so this step is robust to however many stray
///      events land before, after, or interleaved with it — landing on
///      the winner's branch with NO competing commit ever published
///      and so NO cache-poisoning fork.
///
/// Because only one finalized SelfRemove commit ever exists, there is
/// nothing to reconcile. Convergence is verified two ways: a residual
/// member-set check on BOTH peers, AND a direct MLS-epoch equality
/// check read from each peer's own MDK state (`currentEpoch`) — the
/// load-bearing signal, since a matching member set alone cannot
/// distinguish a reconciled group from a fork (both branches remove
/// Alice; only a fork could leave the two peers on different epochs
/// with the same member set). A fresh post-handoff location publish +
/// decrypt is kept only as a NON-GATING sanity step: MDK's
/// `DEFAULT_EPOCH_LOOKBACK` (5 past epochs) means a location encrypted
/// at the winner's epoch can still decrypt correctly on the loser
/// several epochs later even WITHOUT convergence, so a positive decrypt
/// alone is not proof of a shared branch (this previously produced a
/// false positive that let a winner/loser inversion through — the
/// residual member-count check was the only assertion that caught it).
/// Entirely inside the integration test — zero production surface,
/// zero secret exposure.
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

  bool circleHasAlice(CircleWithMembersFfi circle) =>
      circle.members.any((m) => m.pubkey.toLowerCase() == aliceHex);

  // Dark Matter DM-4b note: the pre-migration election this helper used to
  // run here (elect a lex-smallest "winner" peer to publish the
  // SelfRemove auto-commit; have the "loser" stage-then-withhold its own
  // candidate via `finalizeAutoCommit: false`, `clearPendingCommit` it,
  // then forward-apply the winner's commit by captured id) drove Haven's
  // OWN hand-rolled multi-committer-fork resolution for a receiver-side
  // auto-commit. That is exactly the problem class the Dark Matter engine
  // is adopted to own internally (out-of-order / concurrent-commit
  // convergence) — there is no longer a Dart-visible "pending commit" to
  // withhold, clear, or adopt (`finalizeAutoCommit` / `clearPendingCommit`
  // no longer exist; see `synthetic_user.dart`'s `applyArrivalOrdered`
  // doc). Both peers now simply re-apply the SAME growing arrival-ordered
  // buffer independently and the engine is expected to converge them
  // without any Dart-side coordination.
  //
  // KNOWN GAP TO CONFIRM (flagged for the haven-core owner): a bare
  // `SelfRemove` PROPOSAL (`propose_leave`'s return, RFC 9420 §12.1.2)
  // still needs exactly one remaining member's engine to COMMIT it before
  // anyone converges — `haven_core::circle::manager::decrypt_location`
  // folds `ingest.effects.events` into `LocationMessageResult`s but does
  // not appear to surface an engine-emitted `AutoPublish` `PublishWork`
  // item (if the engine emits one) for Haven's relay layer to publish. If
  // that surfacing is genuinely absent, NEITHER peer below will ever
  // observe Alice's removal and this poll will time out — which is the
  // correct, honest failure mode rather than a silently-passing test.
  await _pollUntil<CircleWithMembersFfi?>(
    describe: "${bob.label} converging on Alice's handoff burst",
    probe: () async {
      await bob.applyArrivalOrdered(inbox.snapshot(), relay: relay);
      return bob.getCircle(mlsGroupId);
    },
    satisfied: (circle) => circle != null && !circleHasAlice(circle),
  );
  await _pollUntil<CircleWithMembersFfi?>(
    describe: "${carol.label} converging on Alice's handoff burst",
    probe: () async {
      await carol.applyArrivalOrdered(inbox.snapshot(), relay: relay);
      return carol.getCircle(mlsGroupId);
    },
    satisfied: (circle) => circle != null && !circleHasAlice(circle),
  );

  // Non-gating sanity check only — NOT the convergence signal (see the
  // class doc above for why a positive decrypt alone cannot prove
  // convergence, given the engine's epoch retention). Bob publishes a
  // fresh location and Carol attempts to decrypt it; any failure here is
  // logged and ignored. The actual pass/fail gate is the
  // residual-member-set + epoch-equality check below.
  try {
    final bobCircleForProbe = await bob.getCircle(mlsGroupId);
    if (bobCircleForProbe != null) {
      await bob.publishLocation(
        circle: bobCircleForProbe,
        latitude: bobFakeLatitude,
        longitude: bobFakeLongitude,
        relay: relay,
      );
      await carol.drainPendingCommits(relay: relay, circle: bobCircle);
    }
  } on Object catch (e) {
    debugPrint(
      '[e2e_combined] non-gating post-handoff location sanity check '
      'failed (ignored — not the convergence signal): ${e.runtimeType}',
    );
  }

  final bobFinal = await bob.getCircle(mlsGroupId);
  final carolFinal = await carol.getCircle(mlsGroupId);
  if (bobFinal == null || carolFinal == null) {
    throw StateError(
      '[e2e_combined] a peer circle vanished during the handoff '
      'single-committer election — a peer was inadvertently removed.',
    );
  }

  // The residual member SET matching on both peers is necessary but
  // NOT sufficient — a fork also removes Alice on both branches — so
  // the load-bearing convergence signal is a direct MLS-epoch equality
  // read from each peer's own MDK state: only a single-committer
  // election (never a fork) can leave both peers on the SAME epoch.
  final bobEpoch = await bob.currentEpoch(mlsGroupId);
  final carolEpoch = await carol.currentEpoch(mlsGroupId);
  if (!_residualMembersOk(bobFinal, aliceHex) ||
      !_residualMembersOk(carolFinal, aliceHex) ||
      bobEpoch != carolEpoch) {
    throw StateError(
      '[e2e_combined] handoff election left an unexpected residual: '
      'bobMembers=${bobFinal.members.length} '
      'carolMembers=${carolFinal.members.length} '
      'bobEpoch=$bobEpoch carolEpoch=$carolEpoch (expected Alice gone, '
      '2 members, 1 admin, and equal epochs on both peers).',
    );
  }
  debugPrint(
    '[e2e_combined] handoff converged — both peers independently applied '
    'the arrival-ordered buffer and landed on the same epoch '
    '(epoch=$bobEpoch on both peers).',
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

  // Invalidate ONCE, then DRIVE FRAMES while waiting. Awaiting
  // `circlesProvider.future` inside a non-pumping poll (the previous
  // `_pollUntil` form) could hang indefinitely: under
  // `IntegrationTestWidgetsFlutterBinding` the default `fadePointers` frame
  // policy skips `handleBeginFrame` unless a pump has set `_expectingFrame`,
  // so an invalidated `FutureProvider`'s rebuild is scheduled but never
  // executed and the awaited future never completes (the same reason the
  // Phase-4 probe pumps explicitly). We poll a SYNCHRONOUS `AsyncValue`
  // snapshot instead of awaiting `.future`, so a stuck rebuild can never
  // block the wait: `tester.pump` forces the frame that runs the rebuild,
  // and Riverpod's `_mustRecomputeState` guard keeps the per-frame read from
  // starting a fresh FFI call once the value has settled.
  container.invalidate(circlesProvider);
  await pumpUntilCondition(
    tester,
    () {
      final snapshot = container.read(circlesProvider);
      return snapshot is AsyncData<List<Circle>> && snapshot.value.isEmpty;
    },
    description:
        "Alice's circlesProvider should be empty after her AdminHandoff "
        'leave (corroborating the FFI residual-group proof)',
    timeout: const Duration(seconds: 15),
  );

  final circles = container.read(circlesProvider).value ?? const <Circle>[];
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

// =============================================================================
// M11 live-sync scenario helpers
//
// Support the `group('M11: live-sync (flag-on)')` block. They only run under a
// `--dart-define=HAVEN_LIVE_SYNC=true` build — every M11 scenario self-guards
// with `if (!liveSyncEnabled) return;`, so on the default poll build the
// scenarios return early and never reach these.
// =============================================================================

/// [testWidgets] with a per-test [Timeout] backstop.
///
/// `IntegrationTestWidgetsFlutterBinding` defaults to `Timeout.none`, so an
/// unforeseen stuck `await` — e.g. a live-sync engine start/stop/resubscribe
/// that crosses the FFI + relay boundary — would otherwise hang until CI's
/// outer SIGKILL with NO per-test attribution (the "blind hang" the first
/// flag-on run hit). Routing the live scenarios (and FE-2) through this wrapper
/// bounds each at 4 min — generous over each scenario's ≤90 s internal budget —
/// so a stall fails as a clean, named test failure instead. On the poll build
/// the M11 bodies self-skip in microseconds, so the bound is inert there.
void boundedTestWidgets(
  String description,
  Future<void> Function(WidgetTester tester) callback,
) {
  testWidgets(
    description,
    callback,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

// -----------------------------------------------------------------------
// M11 supersession guard.
//
// `boundedTestWidgets`'s 4-min `Timeout` is a RACE, not a cancellation:
// `package:test` reports the `TimeoutException` and moves on to the next
// scenario, but the original `async` callback keeps running — Dart has no
// Future cancellation. That orphaned continuation shares the SAME process-
// wide `IntegrationTestWidgetsFlutterBinding` (and its `TestAsyncUtils`
// guarded-call bookkeeping) as every OTHER scenario in this file, so once
// it eventually reaches another `tester.pump`/`pumpWidget` call (its own
// polling loop's next iteration, or its `finally` teardown), it collides
// with whatever guarded call the NEXT (now-running) scenario happens to be
// making — flutter_test's "Guarded function conflict" — and can also read
// [ProviderContainer]s the next scenario's `_m11PumpAliceLiveEngine` has
// already disposed.
//
// The fix is a monotonically-increasing generation token: every M11 helper
// that can be "stuck" long enough to straddle a scenario boundary (the
// polling loops) or that runs unconditionally in a `finally` (engine stop /
// MLS wipe / widget-tree teardown) captures the CURRENT generation when its
// owning scenario starts and self-aborts the instant a LATER scenario has
// superseded it — instead of touching `WidgetTester`/the container again.
int _m11Generation = 0;

/// Thrown by the M11 helpers once [_m11Generation] has moved past the
/// generation they were given — i.e. this scenario's own 4-min `Timeout`
/// already fired and a LATER scenario has begun. Caught and swallowed by
/// [_m11ScenarioTestWidgets]: the real failure was already reported via the
/// outer `Timeout`, so this is purely a clean, attributable abort of the
/// orphaned continuation, never a NEW failure on a different scenario.
class _M11ScenarioSuperseded implements Exception {
  const _M11ScenarioSuperseded();
  @override
  String toString() =>
      '_M11ScenarioSuperseded: a later M11 scenario already started; this '
      'continuation is orphaned and must not touch WidgetTester/the '
      'container again.';
}

/// `true` once [generation] is no longer the active M11 scenario — the
/// shared check every M11 pump-loop / teardown helper runs immediately
/// before touching `WidgetTester` or a [ProviderContainer] (no intervening
/// `await` between the check and the guarded call, so nothing can flip
/// [_m11Generation] in between).
bool _m11Superseded(int generation) => generation != _m11Generation;

/// [boundedTestWidgets] wrapper for the M11 group: bumps [_m11Generation]
/// synchronously before [callback] starts (capturing this scenario's own
/// generation) and swallows a superseded-abort cleanly instead of letting it
/// surface as a stray "thrown after the test had completed" block. FE-2 (the
/// OTHER `boundedTestWidgets` user) does not use the M11 helpers and is left
/// on the plain wrapper.
void _m11ScenarioTestWidgets(
  String description,
  Future<void> Function(WidgetTester tester, int generation) callback,
) {
  boundedTestWidgets(description, (tester) async {
    final generation = ++_m11Generation;
    try {
      await callback(tester, generation);
    } on _M11ScenarioSuperseded catch (e) {
      debugPrint('[M11] $e');
    }
  });
}

/// Runs [op] but never lets it hang past [timeout] — mirrors haven-core's own
/// `bounded()` teardown pattern (`relay/live_sync/session.rs`'s
/// `RELAY_LIFECYCLE_OP_TIMEOUT`/`STOP_DRAIN_TIMEOUT`). Every M11
/// teardown/lifecycle step that reaches into the engine or SQLCipher routes
/// through this so a wedged FFI await (e.g. `LiveSyncCore::stop`'s UNBOUNDED
/// `lifecycle.lock().await` contending a stuck `start`/`subscribe_circle` —
/// see the doc on that lock) fails fast with a NAMED, attributable diagnostic
/// instead of silently consuming the whole 4-min scenario budget. A scenario
/// whose `_runTestBody` is starved that long risks its LATE `asyncBarrier()`
/// check misattributing a LATER scenario's legitimate in-flight guarded call
/// as "leaked" (see the M11 supersession guard doc above `boundedTestWidgets`)
/// — bounding every step here shrinks that window from "however long the
/// underlying hang persists" to, at most, the sum of these timeouts.
///
/// Best-effort, like the M11 teardown helpers this backs: swallows a
/// timeout/failure (`${e.runtimeType}` only — Security Rule 8) and NEVER
/// rethrows, so one slow step can never mask the scenario's own assertion or
/// block the rest of teardown. [label] identifies the step in CI logs.
Future<void> _m11Bounded(
  String label,
  Future<void> Function() op, {
  Duration timeout = const Duration(seconds: 25),
}) async {
  try {
    await op().timeout(timeout);
  } on Object catch (e) {
    debugPrint(
      '[M11] $label did not complete within ${timeout.inSeconds}s (or '
      'threw): ${e.runtimeType}',
    );
  }
}

/// Alice's production ProviderScope container (the pumped HavenApp's scope).
ProviderContainer _m11AliceContainer(WidgetTester tester) =>
    ProviderScope.containerOf(
      tester.element(find.byType(HavenApp)),
      listen: false,
    );

/// Pumps HavenApp as Alice — the single live-sync engine in this
/// single-process suite — with her pre-seeded sentinel identity and the
/// deterministic fake geolocator, then waits for MapShell. Under a live-sync
/// build `MapShell.initState` starts the Rust engine (`_startLiveSync`) in
/// place of the receive/evolution/invitation pollers, so every peer event
/// these scenarios assert on reaches Alice over `LiveSyncFfi.liveEvents()`.
///
/// Also awaits Alice's OWN KeyPackage (kind 30443) publish
/// (`keyPackagePublisherProvider`) before returning: `MapShell.initState`
/// fires that provider but does not await it, so without this a scenario's
/// `fetchMemberKeypackage(alice)` (f/g) could race ahead and fetch the
/// PREVIOUS scenario's now-stale 30443 — its private material was just
/// deleted by `_m11WipeAliceMlsState` — producing a Welcome Alice's fresh
/// identity state can never decrypt (`processGiftWrappedInvitation` failure).
///
/// Returns her production container. Throws [_M11ScenarioSuperseded] if
/// [generation] is no longer current by the time a step here would touch
/// `WidgetTester`.
Future<ProviderContainer> _m11PumpAliceLiveEngine(
  WidgetTester tester,
  int generation,
) async {
  final prefs = await SharedPreferences.getInstance();
  final flags = OnboardingFlags(
    introSeen: prefs.getBool(kOnboardingIntroSeenKey) ?? false,
    displayNameSet: prefs.getBool(kOnboardingDisplayNameSetKey) ?? false,
    completed: prefs.getBool(kOnboardingCompletedKey) ?? false,
  );
  if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._e2eProviderOverrides(),
        onboardingControllerProvider.overrideWith(
          (ref) => OnboardingController(flags),
        ),
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
  if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
  await pumpUntilFound(
    tester,
    find.byType(MapShell),
    description: 'MapShell after pumpWidget (M11 live engine)',
    shouldAbort: () => _m11Superseded(generation),
  );
  final container = _m11AliceContainer(tester);
  if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
  await container.read(keyPackagePublisherProvider.future);
  return container;
}

/// Alice (the live engine) creates a NEW circle inviting [invitees], publishes
/// their gift-wrapped Welcomes to [relay], then invalidates + re-reads
/// `circlesProvider` and selects the circle — the exact provider mutation the
/// production create-circle UI performs. That circlesProvider change drives
/// `LiveSyncResubscriber` to STOP+START the engine onto the new circle's `#h`
/// (the B0 re-subscribe), so a mid-session create receives live locations
/// without an app relaunch. Reaches Alice's PRODUCTION `CircleManagerFfi` so
/// the circle lands in the same SQLCipher state the providers + engine read.
/// Returns the created circle's [CircleFfi].
Future<CircleFfi> _m11AliceCreatesCircle({
  required WidgetTester tester,
  required ProviderContainer container,
  required TestRelay relay,
  required List<SyntheticUser> invitees,
  required String name,
}) async {
  final circleService =
      container.read(circleServiceProvider) as NostrCircleService;
  final manager = await circleService.getCircleManagerFfi();

  // Resolve each invitee's freshly-published KeyPackage off the relay. 30443 is
  // addressable (replaceable), so this always fetches the newest bootstrap's
  // KP even when a prior M11 scenario reused the same sentinel seed.
  final relayManager = await RelayManagerFfi.newInstance();
  final members = <MemberKeyPackageFfi>[];
  for (final peer in invitees) {
    await waitForKeyPackage(relay: relay, authorPubkeyHex: peer.pubkeyHex);
    final kp = await relayManager.fetchMemberKeypackage(pubkey: peer.pubkeyHex);
    if (kp == null) {
      throw StateError(
        '[M11] fetchMemberKeypackage returned null for ${peer.label}',
      );
    }
    members.add(kp);
  }

  // Create on Alice's production manager. Copy the secret into a buffer we own
  // and zeroize it straight after (Security Rule 9); the identity service owns
  // the original's lifetime.
  final secret = Uint8List.fromList(
    await container.read(identityNotifierProvider.notifier).getSecretBytes(),
  );
  final CircleCreationResultFfi result;
  try {
    result = await manager.createCircle(
      identitySecretBytes: secret,
      members: members,
      name: name,
      circleType: 'location_sharing',
      relays: <String>[relay.url],
      // Synthetic peers advertise no inbox/NIP-65 relays, so pass Alice's own
      // inbox (the hermetic relay) as the Welcome-delivery fallback — exactly
      // what the production admin flow does (see the FE-2 note).
      creatorFallbackRelays: <String>[relay.url],
    );
  } finally {
    secret.fillRange(0, secret.length, 0);
  }

  // Publish every gift-wrapped Welcome so the invitees can accept off the
  // relay.
  for (final welcome in result.welcomeEvents) {
    final (ok, msg) = await relay.publishAndAwaitOk(welcome.eventJson);
    if (!ok) {
      throw StateError('[M11] relay rejected a Welcome: $msg');
    }
  }

  // Mirror the UI's post-create provider mutation: refresh circlesProvider (so
  // getVisibleCircles re-reads and the resubscriber's circlesProvider listener
  // fires) and select the new circle (so memberLocationsProvider watches it).
  container.invalidate(circlesProvider);
  await container.read(circlesProvider.future);
  final selectedId = result.circle.mlsGroupId.toList();
  container.read(selectedCircleIdProvider.notifier).state = selectedId;

  return result.circle;
}

/// Pumps ~1.5 s of frames so the debounced `LiveSyncResubscriber` can
/// STOP+START the engine onto a newly-created circle before a peer publishes.
/// Best-effort timing only: strfry replays stored events on subscribe, so a
/// slightly-early publish is still delivered — this just tightens the
/// live-push measurement for scenario a. Throws [_M11ScenarioSuperseded] if
/// [generation] is no longer current (see the M11 supersession guard doc
/// above `boundedTestWidgets`).
Future<void> _m11Settle(WidgetTester tester, int generation) async {
  for (var i = 0; i < 6; i++) {
    if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Stops Alice's live-sync engine (idempotent) so the next scenario's fresh
/// HavenApp starts a clean process-global SESSION. Best-effort — a teardown
/// failure must never mask the scenario's own assertion. A no-op once
/// [generation] is superseded: the scenario that owned [container] is an
/// orphaned continuation and a LATER scenario may have already disposed it
/// (see the M11 supersession guard doc above `boundedTestWidgets`).
Future<void> _m11StopEngine(
  ProviderContainer? container,
  int generation,
) async {
  if (container == null || _m11Superseded(generation)) return;
  await _m11Bounded(
    'engine stop (teardown)',
    () => container.read(subscriptionServiceProvider).stop(),
  );
}

/// M11 test-isolation reset: wipes Alice's on-disk MLS/circle state
/// (`circles.db` + `haven_mdk.db` + their SQLCipher keyring keys) between
/// scenarios.
///
/// `PathProviderDataDirectory.getDataDirectory()` — the production circle
/// service's storage root — resolves to a FIXED path for the whole test
/// process; it does not vary per identity or per `ProviderScope`. Every M11
/// scenario's `_m11PumpAliceLiveEngine` therefore reopens the SAME on-disk
/// `circles.db`, and no M11 scenario ever has Alice LEAVE the circle(s) it
/// creates. Without this reset her circle count N grows across the whole
/// group (1 -> 11 over the 10 scenarios); every subsequent scenario's
/// mid-session `_m11AliceCreatesCircle` then forces `LiveSyncResubscriber` to
/// STOP+START the engine onto the WHOLE accumulated set, which on the
/// memory-constrained CI emulator blows past the scenario's fixed
/// 20s/30s/45s wait budget — the root cause of the B0/driver-2/c/e
/// deterministic flakes (scenario `a`, which runs at N=1, passes in 245 ms).
///
/// Runs the SAME production wipe `IdentityNotifier.deleteIdentity` performs
/// on logout (`CircleService.closeAndInvalidate` then `.wipeAllMlsState()`,
/// wrapping the Rust `wipe_all_mls_state`, which deletes both DB files AND
/// both SQLCipher keyring keys) — no test-only FFI, and Alice's identity/
/// seed is untouched (only her LOCAL storage is cleared), so the
/// process-cached `_alicePubkeyHex()` that scenarios `f`/`g` depend on stays
/// valid for every following scenario. Best-effort, like `_m11StopEngine`: a
/// wipe failure here must never mask the scenario's own assertion above it.
///
/// A no-op once [generation] is superseded — the guard that actually matters
/// here: a superseded scenario's `container` may ALREADY be disposed (a
/// LATER scenario's `_m11PumpAliceLiveEngine` swapped in a fresh
/// `ProviderScope` via `tester.pumpWidget`), and reading a disposed
/// [ProviderContainer] throws a `StateError` this function would otherwise
/// only catch reactively (see the M11 supersession guard doc above
/// `boundedTestWidgets`).
Future<void> _m11WipeAliceMlsState(
  ProviderContainer? container,
  int generation,
) async {
  if (container == null || _m11Superseded(generation)) return;
  final circleService = container.read(circleServiceProvider);
  // Bounded + named separately (not one combined try/catch): closing the
  // engine handle and wiping the on-disk SQLCipher state are two distinct FFI
  // round-trips, either of which could wedge — a single diagnostic naming
  // BOTH would not localize which one actually hung.
  await _m11Bounded(
    'Alice circle-service close (teardown)',
    circleService.closeAndInvalidate,
  );
  await _m11Bounded(
    'Alice MLS-state wipe (teardown)',
    circleService.wipeAllMlsState,
  );
}

/// Explicit end-of-scenario widget-tree/`ProviderScope` teardown — see
/// `_m11WipeAliceMlsState`'s doc for why the M11 scenarios each do this
/// rather than relying on the NEXT scenario's `pumpWidget` to dispose the
/// previous tree. Run this AFTER the engine stop so the dispose ordering is
/// engine-first, widget-tree-second. A no-op once [generation] is
/// superseded: this is the exact call site that races the NEXT scenario's
/// own `pumpWidget`/`pumpUntilFound` into flutter_test's "Guarded function
/// conflict" (see the M11 supersession guard doc above `boundedTestWidgets`).
Future<void> _m11TeardownWidgetTree(
  WidgetTester tester,
  int generation,
) async {
  if (_m11Superseded(generation)) return;
  // Bounded like the other teardown steps: `tester.pumpWidget` is a GUARDED
  // WidgetTester call, so if it never settles, `.timeout()` cannot un-leak
  // its `TestAsyncUtils` scope — but it DOES stop this function (and the
  // scenario's own `_runTestBody`) from waiting the full 4-min budget on it,
  // which is what shrinks the window for the leaked-pump cascade (see the
  // supersession guard doc above `boundedTestWidgets`).
  await _m11Bounded(
    'widget-tree teardown',
    () => tester.pumpWidget(const SizedBox.shrink()),
    timeout: const Duration(seconds: 10),
  );
}

/// Lowercase-hex pubkeys Alice's production circle service currently sees for
/// [mlsGroupId]. Reads the manager directly (always fresh), so a stream-driven
/// roster change is reflected without invalidating a provider.
Future<Set<String>> _m11AliceRoster(
  ProviderContainer container,
  List<int> mlsGroupId,
) async {
  final service = container.read(circleServiceProvider);
  final members = await service.getMembers(mlsGroupId);
  return {for (final m in members) m.pubkey.toLowerCase()};
}

/// Pumps until Alice's `memberLocationsProvider` surfaces a live location from
/// [senderPubkeyHex], returning the elapsed time. Deliberately does NOT
/// invalidate the provider: under live-sync the ONLY thing that populates the
/// location cache and invalidates this provider is the engine's `liveEvents`
/// stream (the 30 s receive timer is gated OFF), so a positive result proves
/// the wired live path (engine → router → cache → provider).
///
/// When [expectedLatitude] / [expectedLongitude] are BOTH given, the wait
/// condition is coordinate-aware — it holds only once the cached entry for
/// [senderPubkeyHex] matches those coordinates (within [_coordEpsilon]), not
/// merely once ANY entry for that sender is present. This matters whenever a
/// PRIOR location from the same sender may already be cached (FIND-D1): the
/// cache is a `Map<pubkey, MemberLocation>` (timestamp-wins, one slot per
/// sender — `location_sharing_service.dart`), so a bare presence check would
/// return immediately on stale data and silently skip the wait for a NEWER
/// value to actually land. Omitting both parameters preserves the original
/// presence-only behavior for every other call site.
Future<Duration> _m11AwaitLiveLocation(
  WidgetTester tester,
  ProviderContainer container,
  int generation, {
  required String senderPubkeyHex,
  Duration timeout = const Duration(seconds: 20),
  double? expectedLatitude,
  double? expectedLongitude,
}) async {
  final sender = senderPubkeyHex.toLowerCase();
  final stopwatch = Stopwatch()..start();
  await pumpUntilCondition(
    tester,
    () {
      final locs = container.read(memberLocationsProvider).valueOrNull;
      if (locs == null) return false;
      final entry = locs
          .where((l) => l.pubkey.toLowerCase() == sender)
          .firstOrNull;
      if (entry == null) return false;
      if (expectedLatitude == null || expectedLongitude == null) {
        return true;
      }
      return (entry.latitude - expectedLatitude).abs() < _coordEpsilon &&
          (entry.longitude - expectedLongitude).abs() < _coordEpsilon;
    },
    description: expectedLatitude == null
        ? 'memberLocationsProvider surfaces a live location from '
              '${_redactPk(senderPubkeyHex)}'
        : 'memberLocationsProvider surfaces the EXPECTED coordinates from '
              '${_redactPk(senderPubkeyHex)}',
    timeout: timeout,
    shouldAbort: () => _m11Superseded(generation),
  );
  stopwatch.stop();
  return stopwatch.elapsed;
}

/// Pumps frames (turning the event loop so engine stream events + the converge
/// task run) while polling Alice's production roster for [mlsGroupId] until
/// [gonePubkeyHex] is no longer a member, or [timeout] elapses. Used for the
/// leaver-backstop live path (driver-2): the engine converges a received
/// SelfRemove and evicts the leaver with no manual drain.
Future<void> _m11PumpUntilRosterDrops(
  WidgetTester tester,
  ProviderContainer container,
  int generation, {
  required List<int> mlsGroupId,
  required String gonePubkeyHex,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final gone = gonePubkeyHex.toLowerCase();
  final deadline = DateTime.now().add(timeout);
  var lastSize = -1;
  while (DateTime.now().isBefore(deadline)) {
    if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
    await tester.pump(const Duration(milliseconds: 200));
    Set<String> roster;
    try {
      // Bound each probe so a stuck FFI/provider read cannot block the loop
      // past its deadline (mirrors _pollUntil's hardening for a documented
      // 9-min hang). A TimeoutException is an Object, so it is caught below
      // and retried until the outer deadline expires.
      roster = await _m11AliceRoster(container, mlsGroupId)
          .timeout(const Duration(seconds: 5));
    } on Object {
      continue; // group momentarily mid-commit or a stuck probe; retry
    }
    lastSize = roster.length;
    if (!roster.contains(gone)) return;
  }
  throw StateError(
    '[M11] ${_redactPk(gonePubkeyHex)} still in the roster after '
    '${timeout.inSeconds}s (size $lastSize); the engine did not converge the '
    'removal.',
  );
}

/// Pumps frames while polling `pendingInvitationsProvider` until an invitation
/// for [mlsGroupId] surfaces, or [timeout] elapses. Under live-sync the
/// invitation poller is OFF, so a surfaced invitation proves the engine's
/// inbox #p stream delivered the (back-dated) Welcome and the router
/// invalidated the provider (scenario f).
Future<void> _m11PumpUntilInvitation(
  WidgetTester tester,
  ProviderContainer container,
  int generation, {
  required List<int> mlsGroupId,
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  var lastCount = 0;
  while (DateTime.now().isBefore(deadline)) {
    if (_m11Superseded(generation)) throw const _M11ScenarioSuperseded();
    await tester.pump(const Duration(milliseconds: 200));
    try {
      // Bound the read so a stuck provider future cannot block past the
      // deadline (mirrors _pollUntil's hardening). A TimeoutException is an
      // Object, caught below and retried until the outer deadline expires.
      final invitations = await container
          .read(pendingInvitationsProvider.future)
          .timeout(const Duration(seconds: 5));
      lastCount = invitations.length;
      if (invitations.any((i) => listEquals(i.mlsGroupId, mlsGroupId))) {
        return;
      }
    } on Object {
      continue; // provider momentarily rebuilding or a stuck read; retry
    }
  }
  throw StateError(
    '[M11] no pendingInvitation for the target circle after '
    '${timeout.inSeconds}s (saw $lastCount); the inbox stream did not deliver '
    'the Welcome.',
  );
}

/// Forces Alice's live-sync engine through a stop+start cycle with the SAME
/// (unchanged) circle set — the identical mechanism `LiveSyncResubscriber`
/// runs on a circle-set change (`map_shell.dart`'s `_startLiveSync`), invoked
/// directly so a scenario can force a resubscribe without bootstrapping a
/// throwaway circle. Re-issues a fresh REQ (`since=<persisted cursor>`) for
/// every subscribed circle's group stream and the inbox stream — the
/// mechanism scenarios (d) and (g) rely on to prove a previously
/// undelivered or already-delivered event replays. NOT used by (c) — an
/// event that failed with a wrong-epoch error is never expected to
/// succeed on redelivery (MDK's own sticky `Failed`-message cache; see
/// scenario (c)'s doc comment), so (c) proves the anti-skip/anti-bury
/// property directly off the cursor value instead of forcing a
/// resubscribe.
///
/// `stop()`/`start()` are each bounded (25s) and RETHROW a clear, attributable
/// [StateError] on timeout rather than swallowing it: unlike the M11 teardown
/// helpers, a hang here is a genuine failure this scenario's OWN assertions
/// depend on (the resubscribe must actually complete for `d`/`g` to prove
/// cursor persistence / redelivery dedup), so surfacing it precisely — rather
/// than proceeding silently — is a STRICTLY MORE informative failure than
/// letting the caller's later wait time out with no clue why. Also caps how
/// long this scenario's `_runTestBody` can be starved by a wedged
/// `LiveSyncCore::stop`/`start` (its lifecycle-lock doc explains the hang
/// this guards against), shrinking the leaked-pump cascade window described
/// above `boundedTestWidgets`.
Future<void> _m11ForceResubscribe(ProviderContainer container) async {
  final engine = container.read(subscriptionServiceProvider);
  final circles = await container.read(circlesProvider.future);
  final groups = LiveSyncResubscriber.groupsForCircles(circles);
  final inboxRelays = await container.read(inboxRelaysProvider.future);
  await engine.stop().timeout(
    const Duration(seconds: 25),
    onTimeout: () => throw StateError(
      '[M11] _m11ForceResubscribe: engine.stop() did not complete within '
      '25s.',
    ),
  );
  await engine
      .start(groups: groups, inboxRelays: inboxRelays)
      .timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw StateError(
          '[M11] _m11ForceResubscribe: engine.start() did not complete '
          'within 25s.',
        ),
      );
}

// NOTE: `_m11PumpUntilEpochAtLeast` was removed (Dark Matter DM-4b) — its
// sole caller was M11 scenario (c), deleted above (see the removal note
// there) because its premise depended on the OLD MDK's sticky-Unprocessable
// poison cache and the now-FFI-less `stageAndFinalizeSelfUpdate`.
