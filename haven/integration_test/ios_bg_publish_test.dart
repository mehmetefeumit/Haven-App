/// iOS background-publish drive target — proves, under a REAL OS-level
/// background transition, that (P1) the native CoreLocation background
/// session handler arms when background sharing is enabled, (P2) kind-445
/// publishes keep reaching the relay while the app is OS-backgrounded, and
/// (P3) flipping background sharing OFF while still backgrounded stops
/// publishing and disarms the session.
///
/// ## What "REAL" means here — and why this lane exists at all
///
/// Every other lane that exercises the paused-publish branch (B7's second
/// test, the Android B1 lane) dispatches `AppLifecycleState.paused`
/// IN-PROCESS via `tester.binding.handleAppLifecycleStateChanged`. That runs
/// MapShell's genuine `_onPaused()`, but the OS never saw a transition: no
/// `applicationDidEnterBackground` fired, the Flutter engine never flipped
/// its own lifecycle plumbing, and the native
/// `HavenBackgroundSessionHandler`'s sessions were never held across an
/// actual backgrounding. This lane closes that gap: the HOST wrapper
/// (`tooling/e2e/ci/run-ios-bg-publish.sh`) launches ANOTHER app
/// (com.apple.Preferences) over Haven mid-drive, so iOS itself delivers
/// `UIApplicationDidEnterBackground` and the engine dispatches the paused
/// state through the same channel a production backgrounding uses. The test
/// isolate keeps running because the simulator never suspends a backgrounded
/// app — a documented property this whole harness relies on
/// (`.github/workflows/e2e-ios.yml`).
///
/// ## Honest ceiling — what this does NOT prove
///
/// The simulator does NOT reproduce real-device background SUSPENSION: it
/// keeps the process alive and the integration_test VM-service attached, so
/// a "background execution stops" bug on hardware (jetsam, true suspension,
/// SLC/BGTask behaviour) cannot surface here. And like B7, this lane fakes
/// `locationServiceProvider`, so the geolocator stream and its AppleSettings
/// are NOT exercised here either — B4 owns the real-GPS path, and the static
/// guard pins the settings source. What this lane proves is the
/// native-session-arming and Dart publish-pipeline CONTINUITY under a
/// genuinely fired `applicationDidEnterBackground` — not the OS's suspension
/// heuristics. The physical-device checklist
/// (`docs/M7_BACKGROUND_SHARING.md` §6, item 0) remains the final proof.
///
/// ## The host↔test handshake
///
/// 1. This test enables background sharing through the production
///    `BackgroundSharingNotifier.setEnabled` path, asserts the native
///    session status (P1), prints [kSessionArmedMarker], then prints
///    [kReadyForBackgroundMarker].
/// 2. The wrapper tails the flutter-test log for the READY marker, then
///    backgrounds the app by launching com.apple.Preferences over it.
/// 3. This test bounded-polls `WidgetsBinding.instance.lifecycleState` (plus
///    a [WidgetsBindingObserver], in case the state passes through paused
///    transiently) until the REAL paused transition lands, then runs P2/P3.
/// 4. After the final marker, the wrapper re-foregrounds Haven so the
///    flutter_test post-suite teardown gets real frames again.
///
/// ## Markers — and which shell gate each one feeds
///
/// All five are grepped verbatim by `tooling/e2e/ci/run-ios-bg-publish.sh`,
/// and they are NOT interchangeable:
///
///   * [kReadyForBackgroundMarker] feeds the HANDSHAKE only. It is printed
///     before P2/P3 have run, so it must never be treated as a completion
///     signal.
///   * [kSessionArmedMarker], [kBackgroundPublishMarker],
///     [kNegativeSilenceMarker] and [kSessionDisarmedMarker] feed the
///     terminal COMPLETION gate. Each is printed only after the last
///     assertion of its own phase, and the shell requires ALL FOUR — without
///     them a `skip: true`, a `markTestSkipped` or an early `return` would
///     let the drive exit 0 having proved nothing (CI_HARDENING_BACKLOG.md
///     A3b).
///
/// Change either side of any marker and the lane stops finding it — which
/// fails the lane rather than passing it silently.
///
/// ## Never pump while backgrounded
///
/// From the instant the paused transition lands, frame production is
/// disabled (`SchedulerBinding._setFramesEnabledState(false)`), so a
/// `tester.pump()` awaits a frame that can never arrive — a deadlock,
/// observed for real on the Android B1 lane. Everything after
/// [kReadyForBackgroundMarker] therefore uses plain `Future.delayed` loops:
/// real timers, platform-channel replies and relay callbacks all keep
/// running regardless of frame production.
///
/// Hard-FAILS (never skips) on a non-iOS runtime, following
/// `b4_ios_real_gps_test.dart`'s precedent: this target is invoked by exactly
/// one lane, which boots a simulator, so reaching it anywhere else is a
/// harness misconfiguration — and a skipped drive-side test is textually
/// indistinguishable from a passing one (CI_HARDENING_BACKLOG.md A3b).
library;

import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart'
    show kLocationPublishMaxInterval, kLocationPublishMinInterval;
import 'package:haven/src/pages/map_shell.dart';
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
        iosBackgroundSessionServiceProvider,
        locationServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show FakeLocationService, aliceFakeLatitude, aliceFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilCondition, pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show TestRelayEvent, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed, bytesToHex;
import 'e2e/_lib/throw_time_error_capture.dart';

/// Verbatim marker printed only after P1's LAST assertion has passed: the
/// native handler reported `supported && backgroundActivitySessionHeld` after
/// background sharing was enabled through the production `setEnabled` path.
///
/// One of the four terminal proofs `run-ios-bg-publish.sh`'s completion gate
/// requires — change it here AND there together.
const String kSessionArmedMarker = '[bg-publish] SESSION_ARMED';

/// Verbatim marker that tells the HOST wrapper to background the app by
/// launching com.apple.Preferences over it.
///
/// Printed AFTER P1 passes and BEFORE any P2/P3 assertion runs, so it can
/// never stand in for a completion proof — the shell's completion gate
/// deliberately does not accept it.
const String kReadyForBackgroundMarker = '[bg-publish] READY_FOR_BACKGROUND';

/// Verbatim marker prefix printed only after P2's last assertion: at least
/// two kind-445 events for this circle reached the relay AFTER the real
/// backgrounding instant. Carries a trailing ` count=<n>`; the shell matches
/// the PREFIX, so the suffix is free to change.
const String kBackgroundPublishMarker = '[bg-publish] BACKGROUND_PUBLISH_OK';

/// Verbatim marker printed only after P3's silence assertion: over a bounded
/// settle window after `setEnabled(enabled: false)`, the relay-side event-id
/// set for this circle gained nothing created after the disable cutoff.
const String kNegativeSilenceMarker = '[bg-publish] NEGATIVE_SILENCE_OK';

/// Verbatim marker printed only after the final assertion of the whole test:
/// the native handler reported the background session RELEASED after the
/// disable. Printed LAST, so the host also uses it as the signal to
/// re-foreground the app for teardown.
const String kSessionDisarmedMarker = '[bg-publish] SESSION_DISARMED';

/// How long the test waits for the REAL paused transition after printing
/// [kReadyForBackgroundMarker].
///
/// The host wrapper polls the log every 5 s and then issues two `simctl`
/// calls, so the healthy case is seconds; 180 s absorbs a loaded macOS
/// runner scheduling both the poll and the app switch.
const Duration _pausedTransitionWindow = Duration(seconds: 180);

/// How long P2 waits for two post-backgrounding kind-445 publishes.
///
/// The per-circle scheduler is jittered over `kLocationPublishMinInterval`..
/// [kLocationPublishMaxInterval] (72–168 s), so two consecutive ticks can
/// take up to 2 × 168 s in the worst case; 60 s of slack covers the encrypt
/// + relay round trips on a loaded runner. 396 s total.
final Duration _postBackgroundPublishWindow =
    kLocationPublishMaxInterval * 2 + const Duration(seconds: 60);

/// How long P3 waits after the disable before re-fetching the relay's
/// event-id set.
///
/// Sized to one full max-jitter interval ([kLocationPublishMaxInterval],
/// 168 s) plus slack: if the scheduler survived the disable, its next tick
/// MUST land inside this window, so a clean re-fetch afterwards is a real
/// absence proof rather than a lucky early read.
final Duration _negativeSettleWindow =
    kLocationPublishMaxInterval + const Duration(seconds: 32);

/// In-flight grace applied to the P3 diff, in seconds.
///
/// A publish tick that began just before the disable finishes on its own and
/// stamps `created_at` within a second or two of the cutoff. Ticks are
/// spaced ≥ `kLocationPublishMinInterval` (72 s) apart, so a scheduler that
/// SURVIVED the disable produces events far beyond this grace — the
/// discrimination stays sharp.
const int _inFlightGraceSecs = 10;

/// How long each relay snapshot fetch listens before returning what it has.
///
/// `TestRelay.collectN` resolves with the PARTIAL set on timeout (a relay
/// error surfaces as a thrown exception instead), so for a snapshot the
/// timeout IS the completion mechanism, and "collected nothing new" is
/// distinguishable from "the fetch broke".
const Duration _snapshotFetchWindow = Duration(seconds: 15);

/// How long the P3 disarm-status poll waits for the native handler to report
/// the session released (`setEnabled(false)` disarms fire-and-forget).
const Duration _disarmStatusWindow = Duration(seconds: 60);

/// Cadence of the "still waiting" heartbeat printed during the long waits,
/// so a wedged run leaves evidence in CI instead of minutes of silence.
const Duration _heartbeatInterval = Duration(seconds: 20);

/// Prints a heartbeat every [_heartbeatInterval] while [stillWaiting] holds.
///
/// Never pumps a frame: it runs after the REAL pause has been delivered,
/// where frame production is disabled and `tester.pump()` deadlocks (see the
/// library doc).
Future<void> _heartbeatWhile(
  bool Function() stillWaiting,
  Duration budget,
  String what,
) async {
  var elapsed = Duration.zero;
  while (stillWaiting() && elapsed < budget) {
    await Future<void>.delayed(_heartbeatInterval);
    elapsed += _heartbeatInterval;
    if (!stillWaiting()) return;
    debugPrint(
      '[bg-publish] waiting for $what — ${elapsed.inSeconds}s of '
      '${budget.inSeconds}s elapsed.',
    );
  }
}

/// Records every lifecycle state the binding dispatches.
///
/// Belt to the `lifecycleState` poll: if the state ever passed through
/// `paused` transiently, the observer still saw it even if a poll iteration
/// missed the instant.
class _LifecycleRecorder with WidgetsBindingObserver {
  final Set<AppLifecycleState> seen = <AppLifecycleState>{};

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    seen.add(state);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'iOS bg-publish: native session arms, publishes continue across a REAL '
    'OS backgrounding, and disable stops both',
    (tester) async {
      installThrowTimeErrorLogging();
      // Deliberately NOT `markTestSkipped` on a non-iOS runtime (B4's
      // precedent). This target is invoked by exactly one lane, which boots a
      // simulator; anywhere else is a harness misconfiguration, and A3b is
      // the standing reminder that a skipped drive-side test is textually
      // indistinguishable from a passing one.
      expect(
        Platform.isIOS,
        isTrue,
        reason:
            'ios_bg_publish_test drives the iOS CoreLocation background '
            'sessions and a real UIApplication background transition '
            '(simctl launch over the app). It has no meaning on another '
            'platform, and reaching here off-iOS means the lane pointed at '
            'the wrong device.',
      );

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay override.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice = the production identity, persisted under the PRODUCTION
      // secure-storage key so `identityProvider` loads it exactly as a real
      // launch would. Also seeds BOTH location prominent-disclosure flags —
      // the enable path below is gated on them ("disclosure before
      // collection"). Deliberately does NOT seed kBackgroundSharingKey: the
      // subject of P1 is the production `setEnabled(enabled: true)` path,
      // and pre-seeding the toggle would replace it with the load path.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;

      // `locationServiceProvider` is faked here ON PURPOSE (B7 precedent):
      // this lane's subject is the native session arming and the Dart publish
      // pipeline's continuity across a real backgrounding, not GPS
      // acquisition — that is the B4 lane, deliberately NOT coupled to this
      // one, so a B4 regression cannot redden this lane and vice versa. The
      // wrapper still grants When-In-Use and seeds a `simctl location` fix so
      // no CoreLocation prompt or fixless locationd can wedge the run.
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
          '[bg-publish] circleServiceProvider is not Nostr-backed in this '
          'run — the production publish path this target exercises was '
          'bypassed.',
        );
      }
      final CircleManagerFfi aliceManager;
      try {
        aliceManager = await circleService.getCircleManagerFfi();
      } on Object catch (e) {
        // Security Rule 8: runtimeType only — a raw FFI error can carry MLS
        // group IDs or internal state.
        throw StateError(
          '[bg-publish] the foreground circleServiceProvider could not open '
          'its CircleManagerFfi (${e.runtimeType}). That is a harness '
          'failure, not evidence about background publishing.',
        );
      }

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
            '[bg-publish] fetchMemberKeypackage returned null for Bob — his '
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
            name: 'iOS BG Publish Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            // Bob advertises no inbox relays, so the Welcome-delivery cascade
            // needs the admin's own relay as a fallback.
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'bg-publish',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      if (!creation.welcomeEvents.any(
        (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
      )) {
        throw StateError(
          '[bg-publish] createCircle produced no gift-wrap for Bob.',
        );
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      expect(
        bobCircle.members.length,
        greaterThanOrEqualTo(2),
        reason: 'Bob must have joined the circle at the shared epoch.',
      );

      // The circle above was created straight through CircleManagerFfi, so
      // the app's reactive state has never seen it;
      // `LocationPublishSchedulerNotifier._syncCircles` only arms a
      // per-circle scheduler for circles it observes through
      // `circlesProvider`.
      container.invalidate(circlesProvider);
      await pumpUntilCondition(
        tester,
        () => container
            .read(locationPublishSchedulerProvider.notifier)
            .trackedCircleKeysForTest
            .isNotEmpty,
        description:
            'the per-circle publish scheduler armed a scheduler for the new '
            'circle (proof it is publish-eligible BEFORE the backgrounding)',
        timeout: const Duration(seconds: 60),
      );

      final groupIdHex = bytesToHex(creation.circle.nostrGroupId);

      // Bob is released, the relay socket is NOT: this drive's own relay
      // subscription is the P2/P3 oracle, so it must outlive the pause. Bob
      // must go, though — he holds the same circle, and a stray publish from
      // him would land in the very `#h` scope this test attributes to the
      // app.
      await bob.dispose();

      // ===================================================================
      // P1 — enable background sharing through the PRODUCTION path; the
      // native session handler must report armed.
      // ===================================================================
      //
      // `setEnabled(enabled: true)` runs the real iOS branch: the "Always"
      // escalation request (whose native handler resolves via a timeout
      // guard even when the OS prompt goes unanswered), the consent
      // persist, and the awaited `IosBackgroundSessionService.arm()` —
      // arm-before-state-flip is the session-before-updates rule this
      // asserts against.
      final bgNotifier = container.read(backgroundSharingProvider.notifier);
      await bgNotifier.setEnabled(enabled: true);
      expect(
        container.read(backgroundSharingProvider),
        isTrue,
        reason:
            'backgroundSharingProvider did not flip to true after '
            'setEnabled(enabled: true) — the enable path itself is broken, '
            'so nothing downstream could be attributed to backgrounding.',
      );

      final sessionService = container.read(
        iosBackgroundSessionServiceProvider,
      );
      final armedStatus = await sessionService.status();
      expect(
        armedStatus.supported,
        isTrue,
        reason:
            'The native handler reports CLBackgroundActivitySession '
            'unsupported, which means this simulator runtime is below '
            'iOS 17. The lane requires an iOS 17+ runtime — raise the '
            'runner image / booted device rather than weakening this '
            'assertion.',
      );
      expect(
        armedStatus.backgroundActivitySessionHeld,
        isTrue,
        reason:
            'Background sharing was enabled through the production '
            'setEnabled path, but HavenBackgroundSessionHandler holds no '
            'CLBackgroundActivitySession. Without it, a When-In-Use app has '
            'no supported claim to background location delivery on modern '
            'iOS — the keep-alive contract this lane exists to pin is '
            'unarmed.',
      );
      // Diagnostic only, never asserted: the CLServiceSession is created
      // solely under an "Always" authorization, and the lane grants
      // When-In-Use — but iOS can report a provisional Always after the
      // escalation request, so both values are legitimate here.
      debugPrint(
        '[bg-publish] status after arm: '
        'serviceSessionHeld=${armedStatus.serviceSessionHeld}',
      );
      debugPrint(kSessionArmedMarker);

      // ===================================================================
      // The handshake: ask the host to background the app for REAL, then
      // wait for the OS transition to land.
      //
      // NEVER call `tester.pump()` from here to the `finally` — once the
      // paused state lands, frame production is disabled and a pump awaits
      // a frame that can never arrive (see the library doc).
      // ===================================================================
      final recorder = _LifecycleRecorder();
      WidgetsBinding.instance.addObserver(recorder);
      try {
        debugPrint(kReadyForBackgroundMarker);

        bool pausedSeen() =>
            recorder.seen.contains(AppLifecycleState.paused) ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;

        var waited = Duration.zero;
        while (!pausedSeen() && waited < _pausedTransitionWindow) {
          await Future<void>.delayed(const Duration(seconds: 1));
          waited += const Duration(seconds: 1);
        }
        expect(
          pausedSeen(),
          isTrue,
          reason:
              'No REAL AppLifecycleState.paused arrived within '
              '${_pausedTransitionWindow.inSeconds}s of printing '
              '$kReadyForBackgroundMarker. The host step that should have '
              'fired is the run-ios-bg-publish.sh background step ("xcrun '
              'simctl launch <udid> com.apple.Preferences" after tailing '
              'the log for the READY marker) — check the wrapper output '
              'for a failed launch, a marker-wait timeout, or a renamed '
              'marker (the literal lives in this file and in the wrapper; '
              'change them together). Observed lifecycle states so far: '
              '${recorder.seen}.',
        );
        debugPrint(
          '[bg-publish] real OS backgrounding observed after '
          '${waited.inSeconds}s (states: ${recorder.seen}).',
        );

        // The backgrounding instant. P2's `since` anchors here so the
        // circle-creation traffic published moments ago cannot satisfy it.
        final sinceSecs = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;

        // --- The STRUCTURAL claims first: if the iOS paused branch stopped
        // keeping the publish machinery alive, the empirical waits below
        // would burn their full windows before failing for a reason these
        // state in one line each.
        expect(
          MapShell.shouldKeepPublishingWhilePaused(
            backgroundSharingEnabled: true,
            isIOS: true,
          ),
          isTrue,
          reason:
              'The iOS paused-publish branch is the whole mechanism behind '
              'background sharing on this platform; if this predicate is '
              'false, _onPaused() stops the scheduler and background '
              'sharing is dead.',
        );
        expect(
          container
              .read(locationPublishSchedulerProvider.notifier)
              .isActiveForTest,
          isTrue,
          reason:
              'MapShell._onPaused() stopped the publish scheduler under a '
              'REAL OS backgrounding with background sharing enabled — the '
              'exact regression P2 exists to catch, reported here without '
              'burning the wire window.',
        );

        // =================================================================
        // P2 — publishes CONTINUE while OS-backgrounded: ≥2 kind-445 events
        // for this circle, created after the backgrounding instant.
        // =================================================================
        var collecting = true;
        final collectFuture = relay
            .collectN(
              count: 2,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': sinceSecs,
              },
              timeout: _postBackgroundPublishWindow,
            )
            .whenComplete(() => collecting = false);
        final heartbeat = _heartbeatWhile(
          () => collecting,
          _postBackgroundPublishWindow,
          'two post-backgrounding kind-445 publishes (cadence is jittered '
          '${kLocationPublishMinInterval.inSeconds}-'
          '${kLocationPublishMaxInterval.inSeconds}s per tick)',
        );
        final events = await collectFuture;
        await heartbeat;

        expect(
          events.length,
          greaterThanOrEqualTo(2),
          reason:
              'Only ${events.length} kind-445 event(s) for this circle '
              'reached the relay in the '
              '${_postBackgroundPublishWindow.inSeconds}s after the REAL '
              'OS backgrounding (window = 2 full 72-168s jitter intervals '
              '+ slack, so two ticks MUST fit). The app stopped publishing '
              'when iOS backgrounded it — the regression this lane exists '
              'to catch.',
        );
        debugPrint('$kBackgroundPublishMarker count=${events.length}');

        // =================================================================
        // P3 — the negative twin: disabling background sharing while STILL
        // OS-backgrounded stops publishing (event-id diff over a bounded
        // window, never a bare count) and disarms the native session.
        // =================================================================
        //
        // Baseline snapshot BEFORE the disable. `collectN` resolves with
        // the partial set at `timeout` (errors throw instead), so the
        // short window is the completion mechanism, not a race.
        final baseline = await relay.collectN(
          count: 500,
          filter: <String, dynamic>{
            'kinds': <int>[445],
            '#h': <String>[groupIdHex],
            'since': sinceSecs,
          },
          timeout: _snapshotFetchWindow,
        );
        final baselineIds = baseline.map((e) => e.id).toSet();

        final disableCutoffSecs =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        await bgNotifier.setEnabled(enabled: false);
        expect(
          container.read(backgroundSharingProvider),
          isFalse,
          reason:
              'backgroundSharingProvider stayed true after '
              'setEnabled(enabled: false) — the mid-pause disable path '
              '(_bgSharingPausedSub) never saw a state change, so nothing '
              'below could prove it stops publishing.',
        );

        // The settle window: one full max-jitter interval plus slack, so a
        // scheduler that survived the disable MUST tick inside it.
        var settling = true;
        final settleFuture = Future<void>.delayed(
          _negativeSettleWindow,
        ).whenComplete(() => settling = false);
        final settleHeartbeat = _heartbeatWhile(
          () => settling,
          _negativeSettleWindow,
          'the post-disable silence window to elapse',
        );
        await settleFuture;
        await settleHeartbeat;

        final after = await relay.collectN(
          count: 500,
          filter: <String, dynamic>{
            'kinds': <int>[445],
            '#h': <String>[groupIdHex],
            'since': sinceSecs,
          },
          timeout: _snapshotFetchWindow,
        );
        // The diff, id by id. Events created at/before the cutoff (plus a
        // small in-flight grace) are ticks that had already begun when the
        // disable landed — tolerated and logged. Anything created later
        // means the scheduler outlived the user's withdrawal of consent.
        final leaked = after
            .where((e) => !baselineIds.contains(e.id))
            .where((e) => e.createdAt > disableCutoffSecs + _inFlightGraceSecs)
            .toList(growable: false);
        final straggled = after
            .where((e) => !baselineIds.contains(e.id))
            .where((e) => e.createdAt <= disableCutoffSecs + _inFlightGraceSecs)
            .length;
        if (straggled > 0) {
          debugPrint(
            '[bg-publish] $straggled in-flight publish(es) created at or '
            'before the disable cutoff landed late — tolerated, not a '
            'leak.',
          );
        }
        expect(
          leaked.map((TestRelayEvent e) => e.id).toList(growable: false),
          isEmpty,
          reason:
              '${leaked.length} kind-445 event(s) for this circle were '
              'created MORE than ${_inFlightGraceSecs}s after background '
              'sharing was disabled (while still OS-backgrounded) and '
              'reached the relay within the '
              '${_negativeSettleWindow.inSeconds}s settle window. '
              'Publishing must stop when the user withdraws consent — the '
              'scheduler ticks every 72-168s, so a surviving scheduler '
              'lands far outside the ${_inFlightGraceSecs}s in-flight '
              'grace and this cannot be a straggler.',
        );
        debugPrint(kNegativeSilenceMarker);

        // Disarm is dispatched fire-and-forget by setEnabled(false), so
        // poll the native status on a bounded deadline rather than
        // asserting the first read.
        var disarmed = false;
        var disarmWaited = Duration.zero;
        while (disarmWaited < _disarmStatusWindow) {
          final status = await sessionService.status();
          if (!status.backgroundActivitySessionHeld &&
              !status.serviceSessionHeld) {
            disarmed = true;
            break;
          }
          await Future<void>.delayed(const Duration(seconds: 5));
          disarmWaited += const Duration(seconds: 5);
        }
        expect(
          disarmed,
          isTrue,
          reason:
              'The native handler still holds a CoreLocation background '
              'session ${_disarmStatusWindow.inSeconds}s after background '
              'sharing was disabled. Withdrawal of consent must '
              'deterministically release the OS keep-alive '
              '(HavenBackgroundSessionHandler.disarm invalidates and nils '
              'both sessions).',
        );
        debugPrint(kSessionDisarmedMarker);
      } finally {
        WidgetsBinding.instance.removeObserver(recorder);
        // Restore the lifecycle before returning. Not cosmetic: the REAL
        // pause set `framesEnabled = false`, and `flutter_test`'s own
        // post-test cleanup pumps a frame on every test that did not throw.
        // This in-process dispatch re-enables frame scheduling; the host
        // wrapper additionally re-foregrounds the app (its
        // SESSION_DISARMED trigger) so the engine's native animator — which
        // an in-process dispatch cannot restart — produces real frames
        // again for that pump.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
