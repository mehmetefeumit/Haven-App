/// B7 drive target — proves how Haven behaves under each iOS CoreLocation
/// authorization tier ("When In Use" vs "Always"), and that the copy it shows
/// for that tier is HONEST (`docs/CI_HARDENING_BACKLOG.md`, Workstream B,
/// item B7: "iOS WhenInUse vs Always").
///
/// ## The premise — the opposite of the naive one. Read before editing.
///
/// Background location publishing on iOS does **NOT** require "Always". A
/// `CLLocationManager` session started while the app is FOREGROUNDED, with
/// `allowsBackgroundLocationUpdates = true` and the `location`
/// `UIBackgroundMode` declared, keeps delivering under **When-In-Use**
/// authorization — iOS shows the blue status-bar indicator for exactly that
/// case. Haven depends on this by design:
///
///   * `haven/lib/src/services/geolocator_location_service.dart` (see
///     `_streamSettings`) sets `allowBackgroundLocationUpdates` /
///     `showBackgroundLocationIndicator` from the user's background-sharing
///     INTENT, not from lifecycle state, and its doc says in as many words
///     that "When-In-Use authorization suffices for this foreground-started
///     continuation".
///   * `MapShell._onPaused()` keeps the jittered per-circle publish scheduler
///     and the motion trigger running on the iOS branch purely on
///     [MapShell.shouldKeepPublishingWhilePaused] — which reads
///     `backgroundSharingEnabled && isIOS`. The CoreLocation tier is not
///     consulted anywhere on that path.
///
/// What "Always" actually buys is the RECEIVE-only Significant-Location-Change
/// relaunch after iOS has terminated the app: `HavenSLCHandler.startMonitoring`
/// (`haven/ios/Runner/HavenSLCHandler.swift`) refuses to arm unless
/// `authorizationStatus == .authorizedAlways`, and says so — "the SLC path is
/// purely additive — foreground sharing still works without it".
///
/// So the honest oracle is: **publishing continues across a pause under BOTH
/// tiers**, and that is correct rather than a defect. What legitimately
/// changes with the tier is what the UI CLAIMS. This file therefore never
/// asserts that When-In-Use must fail to publish — such an assertion would
/// encode a false claim about CoreLocation and would go red the day the app
/// behaved correctly.
///
/// ## How this file is driven
///
/// `tooling/e2e/ci/run-b7-ios-auth-tier.sh` runs this target TWICE against the
/// same booted simulator: once after
/// `xcrun simctl privacy UDID grant location-always com.oblivioustech.haven`,
/// once after the same command with the service `location` instead (the
/// While-Using tier). This target is deliberately NOT told which preceded it.
/// It
/// OBSERVES the tier from real CoreLocation, prints it, and asserts the
/// invariants that must hold for THAT tier. The shell owns the cross-run
/// discrimination — that the two runs observed DIFFERENT tiers — because a
/// single run structurally cannot tell "the grant worked" from "both grants
/// collapse to the same thing", and a lane that cannot discriminate is a lane
/// that passes vacuously.
///
/// ## Markers — and which shell gate each one feeds
///
/// All three are grepped verbatim by `tooling/e2e/ci/run-b7-ios-auth-tier.sh`,
/// and they are NOT interchangeable:
///
///   * [kObservedTierMarker] feeds the cross-run DISCRIMINATION gate. It is
///     printed once, near the top of the first test, **before any assertion
///     runs** — so its presence says nothing about whether either test body
///     completed, and it must never be treated as a completion signal.
///   * [kCopyVerdictMarker] and [kPublishVerdictMarker] feed the terminal
///     COMPLETION gate. Each is printed only after the last assertion of its
///     own test, and the shell requires BOTH in EACH of the two tier logs.
///     Without them a `skip: true`, a `markTestSkipped` or an early `return`
///     would let a drive exit 0 having proved nothing while the tier marker
///     kept the discrimination gate green.
///
/// Change either side of any of the three and the lane stops finding them —
/// which now fails the lane rather than passing it silently.
///
/// ## Scope boundary — what this does NOT prove
///
/// The simulator never really suspends an app, and `flutter test` keeps the
/// VM-service attached, so a genuine "iOS froze the process" regression cannot
/// surface here (the same boundary `e2e-ios.yml` documents for its own lanes).
/// What this proves is the app's own tier-dependent logic and copy: the
/// production `MethodChannel` → `HavenLocationAuthHandler` → CoreLocation
/// bridge answers correctly on a real iOS runtime, the provider the settings
/// UI branches on agrees with it, the rendered copy matches the tier, and the
/// publish machinery survives a REAL `AppLifecycleState.paused` and puts a
/// kind-445 on the wire afterwards. Real background delivery on hardware —
/// jetsam, true suspension, SLC/BGTask fire — stays an owner checklist item.
///
/// Skipped (not failed) on non-iOS runtimes: every assertion here is about
/// CoreLocation, which does not exist elsewhere.
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart'
    show
        kBackgroundSharingKey,
        kLocationDisclosureAcceptedKey,
        kLocationDisclosureBackgroundAcceptedKey,
        kLocationPublishMaxInterval;
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/pages/settings/location_settings_page.dart';
import 'package:haven/src/providers/background_location_provider.dart'
    show backgroundSharingProvider;
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show locationPublishSchedulerProvider;
import 'package:haven/src/providers/onboarding_provider.dart'
    show
        OnboardingController,
        OnboardingFlags,
        kOnboardingCompletedKey,
        kOnboardingIntroSeenKey,
        onboardingControllerProvider;
import 'package:haven/src/providers/service_providers.dart'
    show
        circleServiceProvider,
        iosLocationPermissionProvider,
        locationServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/ios_location_auth_service.dart'
    show IosAuthStatus, MethodChannelIosLocationAuthService;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:haven/src/test_keys.dart' show WidgetKeys;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show FakeLocationService, aliceFakeLatitude, aliceFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilCondition, pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed, bytesToHex;

/// Verbatim marker prefix carrying the CoreLocation tier this run actually
/// observed, e.g. `[b7] OBSERVED_TIER=whenInUse`.
///
/// The suffix is an [IosAuthStatus] `.name`: `always`, `whenInUse`, `denied`,
/// `notDetermined`, `restricted` or `unknown`. `tooling/e2e/ci/
/// run-b7-ios-auth-tier.sh` greps this literally out of both runs' logs and
/// fails the lane unless the two runs disagree — change it here AND there
/// together.
///
/// Printed BEFORE the first assertion, deliberately, so that even a failing
/// run reports which grant it was carrying. That is also why it cannot serve
/// as a completion signal: see [kCopyVerdictMarker].
const String kObservedTierMarker = '[b7] OBSERVED_TIER=';

/// Verbatim marker printed once the settings copy has been proven honest for
/// the observed tier — i.e. only after this test's LAST assertion has passed.
///
/// `run-b7-ios-auth-tier.sh`'s completion gate requires it in EACH of the two
/// tier logs, and fails the lane when a drive exited 0 without it. That is the
/// only check that can see a skipped or early-returning body, because
/// [kObservedTierMarker] is printed before any assertion and would still be
/// present.
const String kCopyVerdictMarker = '[b7] COPY_OK';

/// Verbatim marker printed once a kind-445 has been observed on the wire
/// AFTER a real `AppLifecycleState.paused` — i.e. only after this test's last
/// assertion has passed. Carries a trailing ` tier=<name>` so the line is
/// self-contained; the shell matches the PREFIX, so the suffix is free to
/// change.
///
/// Required per tier log by `run-b7-ios-auth-tier.sh`'s completion gate, for
/// the same reason as [kCopyVerdictMarker]. Losing this test is the cheapest
/// way for the lane to go vacuous: an early return skips a 240 s wire wait and
/// looks exactly like a fast, healthy run.
const String kPublishVerdictMarker = '[b7] BACKGROUND_PUBLISH_OK';

/// How long the post-pause wire observation waits for the app's own publish.
///
/// The per-circle scheduler is jittered over
/// `kLocationPublishMinInterval`..`kLocationPublishMaxInterval` (72–168 s,
/// `haven/lib/src/constants/location.dart`), so the worst case for the FIRST
/// tick after arming is one full [kLocationPublishMaxInterval]. 240 s is that
/// worst case plus ~40% slack for the encrypt + relay round trip on a loaded
/// macOS runner.
const Duration _postPausePublishWindow = Duration(seconds: 240);

/// Cadence of the "still waiting" heartbeat printed during
/// [_postPausePublishWindow], so a wedged run leaves evidence in CI instead of
/// four minutes of silence.
const Duration _heartbeatInterval = Duration(seconds: 20);

/// Reads the CoreLocation authorization tier through the PRODUCTION bridge.
///
/// Deliberately not a fake, and not the service resolved from a Riverpod
/// provider: this is the real `MethodChannel` → `HavenLocationAuthHandler` →
/// `CLLocationManager.authorizationStatus` round trip, which only a real iOS
/// runtime can answer. Every host-side test of this bridge uses a fake, so
/// this call is the only place the wiring itself is proven.
Future<IosAuthStatus> _readNativeTier() =>
    const MethodChannelIosLocationAuthService().checkStatus();

/// Seeds the three REAL `SharedPreferences` flags the publish path gates on.
///
/// * [kBackgroundSharingKey] — the user-facing toggle.
/// * [kLocationDisclosureAcceptedKey] — `LocationPublishSchedulerNotifier.
///   _publishCircle` returns early without it ("disclosure before
///   collection"), so a run that skipped it would observe no publish and
///   blame the wrong thing.
/// * [kLocationDisclosureBackgroundAcceptedKey] — without it
///   `BackgroundSharingNotifier._load()`'s fail-closed reconcile drops the
///   toggle back to `false` on the first read.
///
/// Real prefs, never `setMockInitialValues`: this runs on a device and the
/// production notifier reads the real store.
Future<SharedPreferences> _seedPublishPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kBackgroundSharingKey, true);
  await prefs.setBool(kLocationDisclosureAcceptedKey, true);
  await prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, true);
  return prefs;
}

/// Prints a heartbeat every [_heartbeatInterval] while [stillWaiting] holds.
///
/// Never pumps a frame: it runs after the pause has been delivered, where
/// frame production is disabled and `tester.pump()` deadlocks (see the pause
/// site's comment).
Future<void> _heartbeatWhile(
  bool Function() stillWaiting,
  Duration budget,
) async {
  var elapsed = Duration.zero;
  while (stillWaiting() && elapsed < budget) {
    await Future<void>.delayed(_heartbeatInterval);
    elapsed += _heartbeatInterval;
    if (!stillWaiting()) return;
    debugPrint(
      '[b7] waiting for a post-pause kind-445 — ${elapsed.inSeconds}s of '
      '${budget.inSeconds}s elapsed (publish cadence is jittered '
      '${kLocationPublishMaxInterval.inSeconds}s worst case).',
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B7: observes the granted CoreLocation tier and renders honest copy '
    'for it',
    (tester) async {
      if (!Platform.isIOS) {
        markTestSkipped(
          'b7_ios_auth_tier_test asserts CoreLocation authorization-tier '
          'behaviour; skipped on non-iOS runtimes.',
        );
        return;
      }

      // Read and ANNOUNCE the tier before any assertion, so even a failing
      // run tells the shell which grant it was carrying.
      final tier = await _readNativeTier();
      debugPrint('$kObservedTierMarker${tier.name}');

      expect(
        tier,
        anyOf(IosAuthStatus.always, IosAuthStatus.whenInUse),
        reason:
            'No usable CoreLocation authorization was granted before this '
            'run (observed ${tier.name}). The lane grants one with '
            '`xcrun simctl privacy <udid> grant location-always '
            'com.oblivioustech.haven` or `... grant location ...` before '
            'launching; if neither took, this target can discriminate '
            'nothing and every tier-specific assertion below would pass or '
            'fail for the wrong reason.',
      );

      await _seedPublishPrefs();

      // The REAL iosLocationAuthServiceProvider and backgroundSharingProvider
      // must run here — overriding either would replace the subject of the
      // test with a fake and prove only that the fake agrees with itself.
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LocationSettingsPage(),
          ),
        ),
      );
      await pumpUntilFound(
        tester,
        find.byType(LocationSettingsPage),
        description: 'LocationSettingsPage after pumpWidget',
      );

      final pageElement = tester.element(find.byType(LocationSettingsPage));
      final container = ProviderScope.containerOf(pageElement, listen: false);

      // Both async reads must have landed before the copy is inspected: the
      // toggle drives whether the note renders at all, and the permission
      // future drives WHICH branch renders.
      await pumpUntilCondition(
        tester,
        () {
          final tile = tester.widget<SwitchListTile>(
            find.byKey(WidgetKeys.backgroundSharingTile),
          );
          return tile.value &&
              container.read(iosLocationPermissionProvider).hasValue;
        },
        description:
            'the background-sharing toggle read back true from real '
            'SharedPreferences AND iosLocationPermissionProvider resolved',
      );

      // The provider the UI actually branches on must agree with native.
      // A drift here would mean the note is driven by something other than
      // the authorization the user granted.
      expect(
        container.read(iosLocationPermissionProvider).valueOrNull,
        tier,
        reason:
            'iosLocationPermissionProvider disagrees with the production '
            'MethodChannel bridge. LocationSettingsPage branches on the '
            'provider, so the user would be shown copy for a tier they do '
            'not hold.',
      );

      // Resolve the strings from the real localisation rather than hardcoding
      // English, so this stays true under a non-English device locale.
      final l10n = AppLocalizations.of(pageElement);
      final limitedNote = find.text(l10n.locationSettingsIosLimitedNote);
      final guidance = find.text(l10n.locationSettingsIosGuidance);

      const honesty =
          'The ARB pins this copy honest in BOTH directions '
          '(@locationSettingsIosLimitedNote): While-In-Use IS sufficient for '
          'continued background sharing — never claim "Always" is required '
          'for it — and "Always" still genuinely improves catch-up after iOS '
          'terminates the app — never present While-In-Use as loss-free.';

      if (tier == IosAuthStatus.whenInUse) {
        expect(
          limitedNote,
          findsOneWidget,
          reason:
              'While-In-Use is granted and background sharing is on, but the '
              'residual note is absent, so nothing tells the user that '
              'post-termination catch-up will not resume. $honesty',
        );
        expect(
          guidance,
          findsNothing,
          reason:
              'The unqualified iOS guidance card claims Haven can catch up '
              'after iOS closes the app, which needs "Always". Showing it '
              'under While-In-Use would be a false capability claim. '
              '$honesty',
        );
        expect(
          find.text(l10n.commonOpenSettings),
          findsOneWidget,
          reason:
              'The residual note must carry the affordance that lets the '
              'user act on it — a warning with no route to iOS Settings is '
              'a dead end.',
        );
      } else {
        expect(
          limitedNote,
          findsNothing,
          reason:
              '"Always" is granted, so the residual note would tell the user '
              'to change a setting they have already changed. $honesty',
        );
        expect(
          guidance,
          findsOneWidget,
          reason:
              '"Always" is granted, so the page must state what is actually '
              'in force: a continuous session with the blue indicator, plus '
              'catch-up after iOS closes the app. $honesty',
        );
      }

      debugPrint(kCopyVerdictMarker);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  testWidgets(
    'B7: keeps publishing across a REAL pause under the granted tier',
    (tester) async {
      if (!Platform.isIOS) {
        markTestSkipped(
          'b7_ios_auth_tier_test asserts the iOS paused-publish branch; '
          'skipped on non-iOS runtimes.',
        );
        return;
      }

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay override.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice = the production identity, persisted under the PRODUCTION
      // secure-storage key so `identityProvider` loads it exactly as a real
      // launch would.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      // REAL prefs, written BEFORE HavenApp is pumped so
      // `BackgroundSharingNotifier._load()`'s first read observes `true`.
      final prefs = await _seedPublishPrefs();

      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;

      // `locationServiceProvider` is faked here ON PURPOSE. The simulator has
      // no GPS fix unless `simctl location set` seeds one — that is backlog
      // item B4's lane, deliberately NOT coupled to this one, so a B4
      // regression cannot redden B7 and vice versa. This lane's subject is
      // the app's authorization-tier behaviour, not GPS acquisition; the real
      // `AppleSettings` wiring (`allowBackgroundLocationUpdates`,
      // `showBackgroundLocationIndicator`, `pauseLocationUpdatesAutomatically`)
      // is pinned separately and statically by
      // `scripts/ci/check_ios_background_publish.sh`.
      //
      // `onboardingControllerProvider` must be overridden explicitly: its
      // default factory yields `OnboardingFlags.none`, and production only
      // pre-loads it from SharedPreferences inside `main.dart`'s bootstrap,
      // which pumping `HavenApp` directly bypasses.
      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            onboardingControllerProvider.overrideWith(
              (ref) => OnboardingController(
                OnboardingFlags(introSeen: introSeen, completed: completed),
              ),
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
      // pumpUntilFound, not pumpAndSettle — MapShell's own periodic timers
      // keep the frame queue non-empty and pumpAndSettle would hang. See
      // pump_helpers.dart's library doc.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      // Reach into the SAME ProviderContainer MapShell reads from — never a
      // second, drive-owned container — so every read below observes the
      // state the mounted app is actually running on.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      await container.read(identityProvider.future);
      expect(
        container.read(identityProvider).valueOrNull,
        isNotNull,
        reason:
            'identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding — nothing downstream can '
            'publish without an identity.',
      );

      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b7] circleServiceProvider is not Nostr-backed in this run — the '
          'production publish path this target exercises was bypassed.',
        );
      }
      final CircleManagerFfi aliceManager;
      try {
        aliceManager = await circleService.getCircleManagerFfi();
      } on Object catch (e) {
        // Security Rule 8: runtimeType only — a raw FFI error can carry MLS
        // group IDs or internal state.
        throw StateError(
          '[b7] the foreground circleServiceProvider could not open its '
          'CircleManagerFfi (${e.runtimeType}). That is a harness failure, '
          'not evidence about authorization tiers.',
        );
      }

      await pumpUntilCondition(
        tester,
        () => container.read(backgroundSharingProvider),
        description:
            'backgroundSharingProvider resolved true from the persisted '
            'kBackgroundSharingKey',
      );

      // --- Bob: an in-process SyntheticUser, needed only so the circle has a
      // genuine second member and is therefore publish-eligible.
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

      final relayManager = await RelayManagerFfi.newInstance();
      final CircleCreationResultFfi creation;
      try {
        final bobKp = await relayManager.fetchMemberKeypackage(
          pubkey: bob.pubkeyHex,
        );
        if (bobKp == null) {
          throw StateError(
            '[b7] fetchMemberKeypackage returned null for Bob — his '
            'KeyPackage was not found on the relay.',
          );
        }
        // `withFreshSecret` owns the fetch → validate-32-bytes →
        // scrub-in-`finally` contract (Security Rule 9).
        creation = await withFreshSecret(
          () => container
              .read(identityNotifierProvider.notifier)
              .getSecretBytes(),
          // Publishes Bob's gift-wrapped Welcome and CONFIRMS the staged
          // create (Security Rule 13) — an unconfirmed create pins the group
          // in MDK's PendingPublish, where every inbound kind-445 buffers
          // forever.
          (aliceSecret) => createCircleConfirmed(
            manager: aliceManager,
            relay: relay,
            identitySecretBytes: aliceSecret,
            members: <MemberKeyPackageFfi>[bobKp],
            name: 'B7 iOS Auth Tier Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            // Bob advertises no inbox relays, so the Welcome-delivery cascade
            // needs the admin's own relay as a fallback.
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'b7',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      if (!creation.welcomeEvents.any(
        (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
      )) {
        throw StateError('[b7] createCircle produced no gift-wrap for Bob.');
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      expect(
        bobCircle.members.length,
        greaterThanOrEqualTo(2),
        reason: 'Bob must have joined the circle at the shared epoch.',
      );

      // REQUIRED here, unlike the Android B1 lane: on iOS the publisher runs
      // in THIS isolate, and `LocationPublishSchedulerNotifier._syncCircles`
      // only arms a per-circle scheduler for circles it observes through
      // `circlesProvider`. The circle above was created straight through
      // CircleManagerFfi, so the app's reactive state has never seen it.
      container.invalidate(circlesProvider);
      await pumpUntilCondition(
        tester,
        () => container
            .read(locationPublishSchedulerProvider.notifier)
            .trackedCircleKeysForTest
            .isNotEmpty,
        description:
            'the per-circle publish scheduler armed a scheduler for the new '
            'circle (proof it is publish-eligible BEFORE the pause)',
        timeout: const Duration(seconds: 60),
      );

      final groupIdHex = bytesToHex(creation.circle.nostrGroupId);

      // Bob is released, the relay socket is NOT. The Android B1 lane
      // disposed both because its oracle was logcat; here this drive's own
      // relay subscription IS the oracle, so it must outlive the pause. Bob
      // must go, though: he holds the same circle and a stray publish from
      // him would land in the very `#h` scope this test attributes to the
      // app.
      await bob.dispose();

      final sinceSecs = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

      // =====================================================================
      // THE PROOF
      // =====================================================================
      //
      // `handleAppLifecycleStateChanged` is Flutter's OWN public dispatch
      // entry point (`flutter/lib/src/widgets/binding.dart`), which iterates
      // the registered observers — so this runs MapShell's genuine,
      // UNMODIFIED `didChangeAppLifecycleState(paused)` → `_onPaused()`,
      // exactly as a real `UIApplicationDidEnterBackground` would. It is not
      // a hand-written stand-in.
      //
      // NEVER call `tester.pump()` between here and the `finally`.
      // `SchedulerBinding.handleAppLifecycleStateChanged` calls
      // `_setFramesEnabledState(false)` for `paused`, so `scheduleFrame()`
      // stops producing frames and a `pump()` awaits one that can never
      // arrive — a deadlock, observed for real on the Android B1 lane. Plain
      // `Future.delayed` loops are both sufficient and correct: real timers,
      // platform-channel replies and relay callbacks all keep running
      // regardless of frame production.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      try {
        // --- The STRUCTURAL claim: the iOS branch of `_onPaused()` left the
        // publish machinery running. If this flips, the empirical wait below
        // would burn its full window before failing for a reason this states
        // in one line.
        expect(
          MapShell.shouldKeepPublishingWhilePaused(
            backgroundSharingEnabled: true,
            isIOS: true,
          ),
          isTrue,
          reason:
              'The iOS paused-publish branch is the whole mechanism behind '
              'background sharing on this platform. If this predicate is '
              'false, `_onPaused()` stops the scheduler and background '
              'sharing is dead regardless of the CoreLocation tier.',
        );
        expect(
          container
              .read(locationPublishSchedulerProvider.notifier)
              .isActiveForTest,
          isTrue,
          reason:
              'MapShell._onPaused() stopped the iOS publish scheduler. Under '
              'BOTH authorization tiers it must keep running: a '
              'foreground-started CLLocationManager session with '
              'allowsBackgroundLocationUpdates keeps the process executable '
              'under When-In-Use too, so stopping here would break '
              'background sharing for every user who granted While Using.',
        );

        // --- The EMPIRICAL claim: a kind-445 for this circle reaches the
        // relay AFTER the pause. Scoped by `since` to the pause instant so
        // the circle-creation commits published moments ago cannot satisfy
        // it, and by `#h` to this circle so nothing else on the hermetic
        // relay can.
        var collecting = true;
        final collectFuture = relay
            .collectN(
              count: 1,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': sinceSecs,
              },
              timeout: _postPausePublishWindow,
            )
            .whenComplete(() => collecting = false);
        final heartbeat = _heartbeatWhile(
          () => collecting,
          _postPausePublishWindow,
        );
        final events = await collectFuture;
        await heartbeat;

        expect(
          events,
          isNotEmpty,
          reason:
              'No kind-445 for this circle reached the relay in the '
              '${_postPausePublishWindow.inSeconds}s after a real '
              'AppLifecycleState.paused. The app stopped publishing when it '
              'was backgrounded, which is the regression this lane exists '
              'to catch — under EITHER tier, since When-In-Use is '
              'sufficient for a foreground-started background session.',
        );

        final tier = await _readNativeTier();
        debugPrint('$kPublishVerdictMarker tier=${tier.name}');
      } finally {
        // Restore the lifecycle before returning. Not cosmetic: the pause set
        // `framesEnabled = false`, and `flutter_test`'s own post-test cleanup
        // runs `runApp(Container(...)); await pump();` on every test that did
        // not throw — a pump that would await a frame `scheduleFrame()` will
        // not request. It is also the honest state: the app was never
        // backgrounded at the OS level, the lifecycle event was dispatched
        // in-process.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
