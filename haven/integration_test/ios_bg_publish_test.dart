/// iOS background-publish drive target — proves, under a REAL OS-level
/// background transition, that (P1) the native CoreLocation background
/// session handler arms AND the background-capable position stream goes live
/// while still foregrounded, (P2a) the production publish pipeline still
/// reaches the relay from a process iOS has genuinely backgrounded, (P2b)
/// the per-circle scheduler's own timers keep kind-445 publishes reaching the
/// relay while backgrounded, and (P3) flipping background sharing OFF while
/// still backgrounded stops publishing and disarms the session.
///
/// P2a and P2b are separate on purpose: they used to be one assertion, and a
/// process frozen by the OS is indistinguishable from a broken pipeline when
/// only the second is measured (CI runs 32646436116 and 32661622879 both
/// reported "the app stopped publishing" for a process that was not running).
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
/// state through the same channel a production backgrounding uses.
///
/// ## What keeps this drive EXECUTING while backgrounded — and the defect
/// that stopped it twice
///
/// The simulator suspends a backgrounded app just as a device does. What
/// keeps the process executing is the app's own production background claim:
/// `UIBackgroundModes: location` plus a LIVE CLLocationManager updates
/// session created with `allowsBackgroundLocationUpdates` — the contract
/// `HavenBackgroundSessionHandler.swift`'s "Purpose" names, and which the
/// armed `CLBackgroundActivitySession` supplements rather than replaces (that
/// session extends AUTHORIZATION, it is not an execution assertion). This
/// target therefore overrides NOTHING about location and runs the production
/// `GeolocatorLocationService`;
/// `scripts/ci/check_ios_background_publish.sh` check 11 pins the absence of
/// a `locationServiceProvider` override.
///
/// Both CI runs of this lane were suspended ~30 s in, and the simulator's own
/// unified log (run 32661622879's `sim.logarchive`) says why — the app had no
/// properly established background session at the transition:
///
///   * `20:03:28.804` the toggle flip tears the FOREGROUND subscription down
///     (`LocationSubcription #pwrlog client unsubscribing`) — Riverpod runs
///     `locationStreamProvider`'s onDispose synchronously inside
///     `invalidateSelf`, and defers the REBUILD to `markNeedsBuild`.
///   * eight seconds of NO location subscription at all, because under this
///     binding's frame policy that rebuild waits for a pump nobody made.
///   * `20:03:36.433` SpringBoard: `visiblity is no`.
///   * `20:03:36.860` — 0.43 s LATE — `setAllowsBackgroundLocationUpdates:
///     allows:1`, and the replacement subscription starts.
///   * `20:03:36.687`-`.862` locationd: `#Warning Denying process assertion`
///     ×10, and `20:03:38.812` it invalidates the `"Location subscription"`
///     RunningBoard assertion it had been holding on this app.
///   * `20:04:12.273` runningboardd: `Suspending task`, once the app's own
///     `FinishTask` grace expired.
///
/// A background-capable session may only be established while the app is in
/// use; this one was established 0.43 s after it stopped being in use. P1
/// below now pumps and then requires a fresh fix from the REBUILT stream, so
/// the session is live and delivering well before the READY marker, and a
/// deferral like that fails P1 loudly instead of being discovered from a
/// system log.
///
/// ## Honest ceiling — what this does NOT prove
///
/// A simulator has no jetsam, no Significant-Location-Change relaunch and no
/// `BGTaskScheduler`, so a background-execution bug that only those surface
/// cannot show up here. Apple additionally documents the `UIBackgroundModes`
/// key as "not available in Simulator" ("Testing in Simulator versus testing
/// on hardware devices"), and DTS advises against testing background
/// execution there at all — yet that same log shows this simulator's
/// locationd creating a `CLBackgroundActivitySession`, holding a RunningBoard
/// assertion for a location client, and delivering fixes on a 10 s cadence
/// for the whole 1109 s suspension, so the machinery is plainly present. If
/// P2 still reports a suspension after the P1 fix above, that is the
/// evidence that the policy is NOT implemented here and the continuity claim
/// has to move out of CI entirely — do not respond by widening P2's window.
/// What this lane proves is that the production background stack — plist
/// mode, `AppleSettings`, the native session handler, the Dart publish
/// pipeline — survives a genuinely fired `applicationDidEnterBackground` and
/// keeps kind-445 events reaching the relay. The physical-device checklist
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
/// 4. On disabling background sharing it prints [kDisabledMarker]; the
///    wrapper waits P3's settle window out from there and re-foregrounds
///    Haven, because from the disable onward iOS is entitled to suspend this
///    process and only the host can wake it in time for the re-fetch.
/// 5. After the final marker the wrapper re-foregrounds Haven again (a no-op
///    if step 4 already did) so the flutter_test post-suite teardown gets
///    real frames.
///
/// ## Markers — and which shell gate each one feeds
///
/// All six are grepped verbatim by `tooling/e2e/ci/run-ios-bg-publish.sh`,
/// and they are NOT interchangeable:
///
///   * [kReadyForBackgroundMarker] and [kDisabledMarker] feed the HANDSHAKE
///     only. Both are printed before the assertions that follow them, so
///     neither may ever be treated as a completion signal.
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
/// ## Pump BEFORE the READY marker; never after it
///
/// Both halves are load-bearing.
///
/// BEFORE: `IntegrationTestWidgetsFlutterBinding` inherits
/// `LiveTestWidgetsFlutterBindingFramePolicy.fadePointers`, under which
/// `handleBeginFrame` skips the frame unless a `pump()` is in flight — the
/// app's own `scheduleFrame` does not qualify. flutter_riverpod defers every
/// dependent-provider REBUILD to `markNeedsBuild` on the scope element, so a
/// provider that only a widget build can refresh never refreshes without a
/// pump. `locationStreamProvider` is exactly that provider, and the toggle
/// flip is exactly that dependency change (P1 below).
///
/// AFTER: from the instant the paused transition lands, frame production is
/// disabled (`SchedulerBinding._setFramesEnabledState(false)`), so a
/// `tester.pump()` awaits a frame that can never arrive — a deadlock,
/// observed for real on the Android B1 lane. Everything after
/// [kReadyForBackgroundMarker] therefore uses plain `Future.delayed` loops:
/// real timers, platform-channel replies, provider LISTENERS (which fire
/// synchronously, unlike rebuilds) and relay callbacks all keep running
/// regardless of frame production.
///
/// Hard-FAILS (never skips) on a non-iOS runtime, following
/// `b4_ios_real_gps_test.dart`'s precedent: this target is invoked by exactly
/// one lane, which boots a simulator, so reaching it anywhere else is a
/// harness misconfiguration — and a skipped drive-side test is textually
/// indistinguishable from a passing one (CI_HARDENING_BACKLOG.md A3b).
library;

import 'dart:io' show Directory, File, FileMode, Platform;

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
import 'package:haven/src/providers/location_provider.dart'
    show locationStreamProvider;
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
    show circleServiceProvider, iosBackgroundSessionServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/geolocator_location_service.dart'
    show GeolocatorLocationService;
import 'package:haven/src/services/location_service.dart'
    show LocationPermissionStatus;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:haven/src/services/publish_stagger.dart'
    show kPublishStaggerMaxGap;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilCondition, pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show TestRelayEvent, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed, bytesToHex;
import 'e2e/_lib/throw_time_error_capture.dart';

/// Verbatim marker printed only after P1's LAST assertion has passed: the
/// native handler reported `supported && backgroundActivitySessionHeld`, AND
/// the position stream rebuilt by the toggle flip delivered a fresh fix — the
/// two halves of the app's background-location configuration, both
/// established while still foregrounded, as iOS requires.
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

/// Verbatim marker that tells the HOST wrapper background sharing has just
/// been switched OFF, so it can time the re-foregrounding.
///
/// The second HANDSHAKE-only marker, and it exists because the disable
/// removes the app's right to run in the background: from that instant iOS
/// may suspend this process, and a suspended process cannot re-fetch the
/// relay when P3's settle window ends. It has to be fetched then — kind-445
/// application messages carry a 228 s NIP-40 `expiration`, so a leak
/// published early in the window is EVICTED from the relay barely half a
/// minute after the window closes, and a late re-fetch would find silence
/// whether or not the disable worked. The host therefore waits the window
/// out from this marker and re-foregrounds the app itself.
///
/// Like [kReadyForBackgroundMarker] it is printed BEFORE the assertions it
/// precedes, so the completion gate deliberately does not accept it.
const String kDisabledMarker = '[bg-publish] BACKGROUND_SHARING_DISABLED';

/// Name of the append-only file the drive writes into its OWN sandbox `tmp/`
/// to signal the host, in `Directory.systemTemp` — `<data container>/tmp` on
/// iOS.
///
/// The host matches on this NAME across every container under the device's
/// `Containers/Data/Application` root, and must keep doing so: it installs the
/// app (to grant it location) before the drive runs, and the drive's own
/// install then rotates the container's leaf UUID. A host that resolved one
/// container up front would watch a directory this file never lands in — CI
/// run 32618134993, where the drive wrote `…/7ECBFB3C…/tmp` while the host
/// polled `…/29407E44…/tmp`, so the app was never backgrounded and the wait
/// below timed out blaming the handshake.
///
/// Carries the three markers the host must act on WHILE the drive is still
/// running: [kReadyForBackgroundMarker] (background the app now),
/// [kDisabledMarker] (start timing P3's settle window) and
/// [kSessionDisarmedMarker] (re-foreground it for teardown). The host greps
/// this file for those literals, exactly as it used to grep the log.
///
/// The handshake CANNOT ride the log. When a printed marker reaches that log
/// is the test REPORTER's decision, not this test's: under the `github`
/// reporter flutter_tools picks by default in CI, a test's whole output is
/// held and flushed as one `::group::` when the test ENDS. In CI run
/// 32553078705 the drive's entire 119-line output — startup through this
/// test's own failure — landed in the log within a single second, nine minutes
/// after it was produced. A marker the host can only read post-mortem cannot
/// trigger a backgrounding the drive is still waiting for, so the lane could
/// never pass. (`run-ios-sim-scenario.sh` now pins `--reporter expanded`, for
/// the watchdog's sake, which happens to make prints stream — but a handshake
/// resting on that would have to be re-proven against every future reporter
/// and flush decision.) A file write reaches the filesystem immediately and is
/// visible to the host at once, whatever the reporter does.
///
/// The wrapper deletes every copy of this file before launching the drive, so
/// a signal left by a previous attempt can never be mistaken for this one's —
/// including one in a container the rotation later hands back. Change the name
/// here AND in `run-ios-bg-publish.sh` together.
const String kHandshakeSignalFileName = 'bg-publish-handshake';

/// Verbatim marker prefix printed only after P2's last assertion: at least
/// two kind-445 events for this circle, from the per-circle scheduler's OWN
/// jittered timers, reached the relay AFTER the real backgrounding instant.
/// Carries a trailing ` count=<n>`; the shell matches the PREFIX, so the
/// suffix is free to change.
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

/// How long P1 waits for the REBUILT position stream to deliver a fresh fix.
///
/// The wrapper drips a new simulated fix every 10 s and a freshly started
/// CLLocationManager session normally delivers the current one at once, so
/// the healthy case is sub-second; 60 s is six drip intervals.
const Duration _streamFreshnessWindow = Duration(seconds: 60);

/// How long P2a waits for the kind-445 from the tick it DRIVES immediately
/// after the backgrounding.
///
/// Bounded from both ends, which is why it is small. Below: the only
/// scheduled delay inside a tick is one decorrelation gap (at most
/// [kPublishStaggerMaxGap], 9 s), and everything after it — the warm-fix
/// read, the MLS encrypt and one localhost relay round trip — took ~0.2 s in
/// CI run 32661622879, so 15 s of slack is ~75x the measured cost. Above:
/// P2a exists to answer "does the pipeline work here at all" BEFORE P2b's
/// long window, so it must land inside the ~30 s of background execution the
/// app gets even with no location keep-alive at all. Widening it would only
/// blur the two answers back together.
final Duration _drivenPublishWindow =
    kPublishStaggerMaxGap + const Duration(seconds: 15);

/// How long P2b waits for two scheduler-timed post-backgrounding publishes.
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

/// How long P3's post-settle relay snapshot listens before returning what it
/// has.
///
/// `TestRelay.collectN` resolves with the PARTIAL set on timeout (a relay
/// error surfaces as a thrown exception instead), so for a snapshot the
/// timeout IS the completion mechanism, and "collected nothing new" is
/// distinguishable from "the fetch broke". It runs after the host has
/// re-foregrounded the app, so unlike everything between the backgrounding
/// and the disable it is under no execution-window pressure.
const Duration _snapshotFetchWindow = Duration(seconds: 15);

/// How long the P3 disarm-status poll waits for the native handler to report
/// the session released (`setEnabled(false)` disarms fire-and-forget).
const Duration _disarmStatusWindow = Duration(seconds: 60);

/// How long the pre-mount permission gate waits for authorization.
///
/// The wrapper grants When-In-Use before the app's first launch, so the
/// healthy case is the first read; 90 s (B4's budget) absorbs
/// CLLocationManager's own start-up latency without burning the attempt on a
/// grant that never applied.
const Duration _authWaitBudget = Duration(seconds: 90);

/// Cadence of the "still waiting" heartbeat printed during the long waits,
/// so a wedged run leaves evidence in CI instead of minutes of silence.
const Duration _heartbeatInterval = Duration(seconds: 20);

/// How far past its own duration a bounded wait may overrun before the
/// overrun can only mean the OS stopped scheduling this process.
///
/// Derived from [_heartbeatInterval], the coarsest interval at which this
/// isolate is KNOWN to be executing: while a wait runs, a heartbeat fires
/// every 20 s off the same event loop, so six consecutive misses is the
/// statement "this isolate did not run for two minutes". Nothing a loaded
/// runner does produces that — a Dart timer fires late by the work queued
/// ahead of it, and this isolate has none while it waits. In CI run
/// 32646436116 P2's then-396 s wait returned after ~1550 s, because iOS had
/// suspended the app ~30 s into the background and every timer resumed
/// together when the host re-foregrounded it: an overrun 10x this bound.
final Duration _suspensionSlack = _heartbeatInterval * 6;

/// Fails with a suspension attribution when [wall] overran [budget] by more
/// than [_suspensionSlack] — the process was frozen, so nothing measured
/// across that window says anything about the app's publishing.
///
/// Called before the empirical assertion it protects, so a suspended run
/// never reports itself as "the app stopped publishing".
void _failIfSuspended(Duration wall, Duration budget, String phase) {
  if (wall <= budget + _suspensionSlack) return;
  fail(
    'iOS SUSPENDED the app during $phase: a ${budget.inSeconds}s wait took '
    '${wall.inSeconds}s of wall clock, so this process was not executing '
    'for ~${(wall - budget).inSeconds}s of it. Nothing measured across that '
    'window says anything about the publish pipeline, and the in-process '
    'oracle cannot measure a frozen process. The keep-alive that should have '
    'prevented this is `UIBackgroundModes: location` plus a LIVE '
    'CLLocationManager updates session created with '
    '`allowsBackgroundLocationUpdates` — so check, in this order: that P1 '
    'above passed (it now requires a fresh fix from the REBUILT stream, '
    'which is what proves that session was established while the app was '
    'still in use), that HavenBackgroundSessionHandler armed, and that this '
    'target still runs the production `GeolocatorLocationService`. If all '
    'three hold and the process was suspended anyway, the simulator does not '
    'implement the policy and the continuity claim has to leave CI — see the '
    'library doc. Do NOT lengthen the window; it only trades this '
    'attribution for a silent suspension.',
  );
}

/// Polls the production location service until CoreLocation reports
/// `whileInUse` or `always`, or [_authWaitBudget] expires.
///
/// NEVER calls `requestPermission()`: on a headless simulator the system
/// prompt has no one to answer it, which is a hang rather than a failure.
Future<void> _awaitLocationAuthorization() async {
  final service = GeolocatorLocationService();
  final deadline = DateTime.now().add(_authWaitBudget);
  var last = LocationPermissionStatus.notDetermined;

  while (DateTime.now().isBefore(deadline)) {
    last = await service.checkPermission();
    if (last == LocationPermissionStatus.whileInUse ||
        last == LocationPermissionStatus.always) {
      debugPrint('[bg-publish] CoreLocation authorization: $last');
      return;
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  throw StateError(
    '[bg-publish] CoreLocation authorization never reached '
    'whileInUse/always within ${_authWaitBudget.inSeconds}s (last status: '
    '$last). The wrapper grants it BEFORE the app is first launched '
    '(`simctl privacy grant location` resolves the bundle id against '
    'INSTALLED apps, and the grant does not survive an uninstall) — so this '
    'is the install/grant/uninstall ordering in run-ios-bg-publish.sh, not a '
    'wait that needs lengthening.',
  );
}

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

      // Real CoreLocation authorization, checked BEFORE `HavenApp` mounts: a
      // mounted MapShell reaches `getCurrentLocation()`, which prompts on a
      // `denied` read — and a system prompt nobody can answer is a hang, not
      // a failure. B4's precedent, and load-bearing here for the same reason
      // it is there: this target runs the PRODUCTION location service.
      await _awaitLocationAuthorization();

      // `locationServiceProvider` is deliberately NOT overridden — see the
      // library doc. The production `GeolocatorLocationService` is what
      // creates the CLLocationManager session carrying
      // `allowBackgroundLocationUpdates`, and that session is the app's only
      // claim to EXECUTE while backgrounded; faking it makes P2 measure a
      // suspended process. The wrapper grants When-In-Use and seeds a
      // `simctl location` fix, so the fix this app publishes comes from the
      // simulator's own location stack.
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
      // The fix the FOREGROUND-only stream last delivered, so the wait below
      // can require a genuinely NEW one. A rebuilt `StreamProvider` carries
      // its predecessor's value through `AsyncLoading`, so `hasValue` alone
      // would be satisfied by the stream this flip is about to tear down.
      final preEnableFixAt = container
          .read(locationStreamProvider)
          .valueOrNull
          ?.timestamp;
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

      // The armed session is only HALF the configuration. The other half —
      // the CLLocationManager updates session carrying
      // `allowBackgroundLocationUpdates: true` — is created by a rebuild of
      // `locationStreamProvider`, and the flip above only did the
      // synchronous half of that: Riverpod's `invalidateSelf` ran the
      // provider's onDispose at once (cancelling the FOREGROUND session)
      // and deferred the rebuild to `markNeedsBuild`. Under this binding's
      // frame policy that rebuild waits for a pump (library doc), so
      // without the pump below the app enters the background having just
      // torn its only location session down and never replaced it — the
      // exact state CI runs 32646436116 and 32661622879 were both measuring
      // without knowing it. Legal here and only here: the REAL pause has
      // not been requested yet.
      await tester.pump();
      await pumpUntilCondition(
        tester,
        () {
          final at = container
              .read(locationStreamProvider)
              .valueOrNull
              ?.timestamp;
          return at != null && at != preEnableFixAt;
        },
        description:
            'the position stream rebuilt by the background-sharing flip '
            'delivered a fresh fix while the app was still foregrounded '
            '(proof the background-capable CLLocationManager session is '
            'live — iOS only lets such a session start in the foreground, '
            'so there is no later chance to establish it). A timeout here '
            'means either the rebuild never happened or the simulated '
            'location drip stopped: check the wrapper for its '
            '"simulated-location drip" line and for simctl errors.',
        timeout: _streamFreshnessWindow,
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
        // The signal the host actually reads — the printed marker above is
        // for humans reading the preserved log. See kHandshakeSignalFileName
        // for why a file and not the log.
        final handshakeSignal = File(
          '${Directory.systemTemp.path}/$kHandshakeSignalFileName',
        )..writeAsStringSync(kReadyForBackgroundMarker, flush: true);

        bool pausedSeen() =>
            recorder.seen.contains(AppLifecycleState.paused) ||
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused;

        // 250 ms, not a second: P2a below has to run while the process is
        // still executing, and on a run where the background keep-alive does
        // NOT hold that budget is the ordinary ~30 s finish-task grace. A
        // coarse poll spends it before the phase it feeds even begins.
        const pausePollInterval = Duration(milliseconds: 250);
        var waited = Duration.zero;
        while (!pausedSeen() && waited < _pausedTransitionWindow) {
          await Future<void>.delayed(pausePollInterval);
          waited += pausePollInterval;
        }
        expect(
          pausedSeen(),
          isTrue,
          reason:
              'No REAL AppLifecycleState.paused arrived within '
              '${_pausedTransitionWindow.inSeconds}s of writing the READY '
              'handshake signal to ${handshakeSignal.path}. The host step that '
              'should have fired is the run-ios-bg-publish.sh background '
              'step ("xcrun simctl launch <udid> com.apple.Preferences" '
              "once a file of that name appears under the device's "
              'Containers/Data/Application root) — check the wrapper output '
              'for a failed launch, a signal-wait timeout, or an app-data '
              'root it could not resolve. The file name lives in this file '
              'and in the wrapper; change them together. Observed lifecycle '
              'states so far: '
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
        // P2a — the publish PIPELINE works from a process iOS has genuinely
        // backgrounded, established within seconds rather than inferred from
        // a 396 s silence.
        //
        // `triggerTickForTest` enqueues onto the production chain exactly as
        // the jittered timer does — same `_onCircleTick`, same `_active`
        // gate, same warm-fix read, same `publishLocation` — and resolves
        // when that link has run; only the timer is bypassed, and
        // `JitteredScheduler` owns the re-arm, so P2b's independent timers
        // are untouched. It separates the two questions P2 used to conflate:
        // "can this process still publish at all" (here, answerable inside
        // any background grace) from "does iOS keep it running long enough
        // to publish twice" (P2b, answerable only if the keep-alive works).
        // =================================================================
        final circleKey = container
            .read(locationPublishSchedulerProvider.notifier)
            .trackedCircleKeysForTest
            .single;

        var driving = true;
        final drivenStartedAt = DateTime.now();
        final drivenFuture = relay
            .collectN(
              count: 1,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': sinceSecs,
              },
              timeout: _drivenPublishWindow,
            )
            .whenComplete(() => driving = false);
        final drivenHeartbeat = _heartbeatWhile(
          () => driving,
          _drivenPublishWindow,
          'the kind-445 from the per-circle tick driven while backgrounded',
        );
        await container
            .read(locationPublishSchedulerProvider.notifier)
            .triggerTickForTest(circleKey);
        final drivenEvents = await drivenFuture;
        final drivenWall = DateTime.now().difference(drivenStartedAt);
        await drivenHeartbeat;

        _failIfSuspended(
          drivenWall,
          _drivenPublishWindow,
          'P2a (the driven backgrounded publish)',
        );
        expect(
          drivenEvents,
          isNotEmpty,
          reason:
              'A per-circle publish tick driven through the production '
              'scheduler from an OS-backgrounded process put no kind-445 for '
              'this circle on the relay within '
              '${_drivenPublishWindow.inSeconds}s. The tick itself resolved, '
              'so the break is inside the pipeline, not in how long iOS let '
              'this process run: the warm stream fix was dropped, the MLS '
              'encrypt failed, or the relay socket did not survive the '
              'backgrounding. P2b below is the separate question of whether '
              'the scheduler keeps FIRING.',
        );

        // =================================================================
        // P2b — publishes CONTINUE while OS-backgrounded: ≥2 kind-445 events
        // for this circle from the scheduler's OWN jittered timers.
        //
        // `since` anchors after P2a's driven event so that event cannot
        // count toward the two: the claim is about timers firing, not about
        // this test's ability to call a method.
        // =================================================================
        final timedSinceSecs =
            DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 1;
        var collecting = true;
        final collectStartedAt = DateTime.now();
        final collectFuture = relay
            .collectN(
              count: 2,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': timedSinceSecs,
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
        final collectWall = DateTime.now().difference(collectStartedAt);
        await heartbeat;

        // Before the count: a frozen isolate collects nothing for reasons
        // that have nothing to do with the publish pipeline — and P2a having
        // just passed makes that reading the only one left.
        _failIfSuspended(
          collectWall,
          _postBackgroundPublishWindow,
          'P2b (the post-backgrounding publish window)',
        );
        expect(
          events.length,
          greaterThanOrEqualTo(2),
          reason:
              'Only ${events.length} scheduler-timed kind-445 event(s) for '
              'this circle reached the relay in the '
              '${_postBackgroundPublishWindow.inSeconds}s after the REAL '
              'OS backgrounding (window = 2 full 72-168s jitter intervals '
              '+ slack, so two ticks MUST fit). P2a proved the pipeline '
              'itself still works from this backgrounded process, so the '
              'per-circle timers stopped firing: the app stopped publishing '
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
        // The DIRECT half of the negative proof, asserted from the still-
        // backgrounded process the instant consent is withdrawn: MapShell's
        // mid-pause watcher tore the publish driver down. The settle-window
        // diff below is the wire-level half, and it needs this one: if iOS
        // suspends this process for the whole window (which it is entitled
        // to do the moment the keep-alive is released — the very behaviour
        // being proven), silence on the wire is what a suspended app
        // produces whether or not the disable worked. This assertion cannot
        // pass vacuously: `_active` is a fact about the app's own state,
        // and it is only false because the C4 watcher ran.
        expect(
          container
              .read(locationPublishSchedulerProvider.notifier)
              .isActiveForTest,
          isFalse,
          reason:
              'The per-circle publish scheduler was still ACTIVE after '
              'background sharing was disabled while OS-backgrounded. '
              "MapShell._onPaused()'s _bgSharingPausedSub watcher is what "
              'must stop it on the true→false consent edge (C4); with it '
              'broken, publishing outlives the withdrawal of consent for as '
              'long as the OS keeps this process alive (privacy Rule 10).',
        );
        // Hand the host the disable instant. From here the app has NO claim
        // to execute in the background — that is the guarantee being proven —
        // so iOS may suspend it for the whole settle window, and only the
        // host can wake it in time for the re-fetch below to happen inside
        // the events' 228 s NIP-40 TTL. See [kDisabledMarker].
        debugPrint(kDisabledMarker);
        handshakeSignal.writeAsStringSync(
          '\n$kDisabledMarker',
          mode: FileMode.append,
          flush: true,
        );

        // The settle window: one full max-jitter interval plus slack, so a
        // scheduler that survived the disable MUST tick inside it. Wall
        // clock, not execution time: it elapses whether iOS suspended this
        // process or not, and a suspended app publishing nothing is the
        // guarantee holding, never a vacuous pass — a disable that did NOT
        // work leaves the keep-alive armed, the app running and the
        // scheduler ticking, which is exactly what the diff below sees.
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
        // disable landed — tolerated and logged. Anything created later,
        // WITHIN the settle window, means the scheduler outlived the user's
        // withdrawal of consent.
        //
        // The upper bound is the window, not "for ever": the host
        // re-foregrounds this app once the window has elapsed (see
        // [kDisabledMarker]), and a foregrounded Haven publishes by
        // design — background consent is not what gates that. Counting a
        // post-window foreground publish as a leak would fail this lane for
        // the app behaving correctly. It costs no discrimination: a
        // scheduler that survived the disable ticks every 72-168 s, and the
        // window is a full max-jitter interval, so it lands INSIDE it.
        final leakWindowEnd =
            disableCutoffSecs + _negativeSettleWindow.inSeconds;
        final leaked = after
            .where((e) => !baselineIds.contains(e.id))
            .where((e) => e.createdAt > disableCutoffSecs + _inFlightGraceSecs)
            .where((e) => e.createdAt <= leakWindowEnd)
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
        // Appended, not printed-only: the host re-foregrounds on this signal
        // so the `finally` below pumps against a live native animator.
        handshakeSignal.writeAsStringSync(
          '\n$kSessionDisarmedMarker',
          mode: FileMode.append,
          flush: true,
        );
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
