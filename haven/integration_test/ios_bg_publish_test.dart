/// iOS background-publish drive target — proves, under a REAL OS-level
/// background transition, that (P1) the native CoreLocation background
/// session handler takes the posture its authorization tier calls for AND the
/// background-capable position stream goes live while still foregrounded,
/// (P2a) the production publish pipeline still reaches the relay from a
/// process iOS has genuinely backgrounded, (P2b) the per-circle scheduler's
/// own timers keep kind-445 publishes reaching the relay while backgrounded
/// AND the session really does coarsen to the 100 m accuracy profile while
/// they do, (P2c / P2d) that process still RECEIVES — through a burst on the
/// live-sync build, through the 90 s catch-up timer on the poll build — and
/// (P3) flipping background sharing OFF while still backgrounded stops
/// publishing and disarms the session.
///
/// P2a and P2b are separate on purpose: they used to be one assertion, and a
/// process frozen by the OS is indistinguishable from a broken pipeline when
/// only the second is measured (CI runs 32646436116 and 32661622879 both
/// reported "the app stopped publishing" for a process that was not running).
///
/// ## Two receive planes, one target, one compile-time branch
///
/// The lane ran `HAVEN_LIVE_SYNC=false` until P4-7, on the reasoning that its
/// subject was the publish side and the receive engine an unrelated axis. That
/// stopped being true when the iOS background pause branch became a BURST
/// plane: every per-circle tick now opens the engine, ingests, publishes,
/// settles and pauses it, so the receive engine is the background publish
/// path's other half. Compiled out, every burst's open fails, the coordinator
/// takes its documented failed-open branch (publish anyway, over the separate
/// publish pool), and the lane measures a degenerate burst — the publish half
/// of a mechanism whose ingest half is exercised under a real backgrounding
/// nowhere at all. That is why the live-sync legs compile the engine IN.
///
/// The flip cost the POLL configuration — the rollback path of a flag that
/// defaults ON — its only real-OS-backgrounding coverage, and nothing
/// substituted for it: no other workflow or harness launches an overlay app
/// over Haven, `e2e-ios` runs its poll variant foregrounded only, and check 6
/// of `check_ios_background_publish.sh` does NOT stand in (it pins the C4
/// watcher and a negative about where that watcher may be installed; a tree
/// with `_startIosBackgroundReceiveTimer` deleted outright still passes it —
/// verified by mutation). OD4-d, §4 of `docs/POWER_EFFICIENCY_PLAN.md`, is the
/// owner decision that closed that gap: the lane now runs a THIRD matrix leg
/// at `HAVEN_LIVE_SYNC=false`, When-In-Use only, and this target branches on
/// the compiled `liveSyncEnabled` to assert the receive plane that build
/// actually has:
///
///   * live-sync build -> **P2c**, the burst: a peer's kind-445 is decrypted
///     into the in-memory member cache and the engine's pool holds no
///     subscription once the burst is over.
///   * poll build -> **P2d**, the timer:
///     `MapShell._startIosBackgroundReceiveTimer`'s `Timer.periodic(90 s)`
///     reaches `CatchupService.runCatchup(isBackgroundWake: true)` from the
///     backgrounded process, and that sweep lands the peer's location in the
///     PERSISTED last-known store.
///
/// The branch is a compile-time one (`liveSyncEnabled` is a
/// `bool.fromEnvironment` const), so exactly one of the two runs and neither is
/// ever skipped — and each prints its OWN terminal proof, which the wrapper's
/// completion gate requires on its leg and REFUSES on the other. A leg whose
/// `--dart-define` and whose `HAVEN_LIVE_SYNC` env came apart therefore reds
/// with attribution instead of quietly measuring the other plane.
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
/// ## Two tier jobs, and why the tier is an INPUT here
///
/// The lane runs this target twice, as a matrix over the CoreLocation grant
/// the host performs: `location` (When-In-Use) and `location-always`. The two
/// jobs assert INVERTED session postures, which is the whole tier→policy
/// mapping OD1 and OD-P3-b rest on:
///
///   * **When-In-Use** — a `CLBackgroundActivitySession` is held and the
///     manager asks for the blue location bar. That is mandatory there and
///     honest; it is also the exact object the 2026-08-20 field failure was
///     missing.
///   * **Confirmed Always** — the `.always` `CLServiceSession` is held, a
///     `CLServiceSessionDiagnostic` has POSITIVELY confirmed the grant, the
///     activity session is released and no indicator is asked for. This is
///     the shape whose only physical neighbour failed in the field, which is
///     why it gets its own job and its own terminal proof marker
///     ([kAlwaysSessionMarker]) rather than riding the other's.
///
/// Which shape a run asserts comes from [kExpectedTierDefine], never from what
/// CoreLocation reports. Reading the tier and branching on it would look
/// tidier and would be the bug: `requestAlwaysAuthorization()` reports
/// `.authorizedAlways` while the second prompt is unanswered, so a simulator
/// that escalated the When-In-Use grant would silently run the Always shape,
/// pass, and leave the lane green while measuring something its header does
/// not describe. Pinned, that escalation is a red run that names itself.
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
/// mode, `HavenLocationStreamHandler`'s updates session, the native session
/// handler's tier posture, the Dart publish pipeline — survives a genuinely
/// fired `applicationDidEnterBackground` and keeps kind-445 events reaching
/// the relay for the lane's window. The physical-device checklist
/// (`docs/M7_BACKGROUND_SHARING.md` §6, item 0) remains the final proof.
///
/// Read the Always job's green with that ceiling in front of it. It shows the
/// confirmed-Always shape — no activity session held, no indicator asked for —
/// surviving a background transition and publishing for ~7 minutes. It does
/// NOT show that shape surviving an AFTERNOON on a device, because the
/// simulator cannot be suspended by the OS the way a phone is and cannot be
/// run for two stationary hours. "Hours stationary under confirmed Always"
/// stays UNKNOWN and is the residual P3 ships with (M7 §6 item 0a, DEFERRED
/// for want of hardware, still owed). Nothing in this file may be cited as
/// having met it.
///
/// ## The profile oracle, and the one thing that would retire it
///
/// P2b polls the native `status()` from the backgrounded process for
/// `hundredMeters`. That question has three possible answers and only the
/// third changes this file:
///
///   1. The simulator delivers under the 100 m tier — the profile drops after
///      the dwell and STAYS coarse while confirming fixes keep arriving. The
///      poll sees it on its first samples.
///   2. The simulator delivers nothing usable under that tier — the confirm
///      deadline escalates back to Best every 84 s, so the coarse profile is
///      a window rather than a steady state. The poll is bounded by
///      `kStationaryDwell + kStationaryConfirmMaxAge` precisely so it still
///      spans one whole such window, and it still sees it.
///   3. The simulator never lets the session run at 100 m at all (the
///      assignment is refused, or the session dies under it). Then this
///      runtime oracle is not answerable HERE: move it to the host-side
///      controller proof in `test/services/ios_location_source_test.dart`,
///      record the downgrade in this doc and in the lane header, and keep
///      P1/P2a/P2b/P3 exactly as they are.
///
/// Answer 3 is the ONLY admissible response to a red profile oracle. Widening
/// the window, sampling more coarsely, or accepting "Best" as evidence would
/// each convert a measurement into a formality — and the tier engaging is the
/// only part of P3's power claim CI can check at all.
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
/// All nine are grepped verbatim by `tooling/e2e/ci/run-ios-bg-publish.sh`,
/// and they are NOT interchangeable:
///
///   * [kReadyForBackgroundMarker] and [kDisabledMarker] feed the HANDSHAKE
///     only. Both are printed before the assertions that follow them, so
///     neither may ever be treated as a completion signal.
///   * [kSessionArmedMarker], [kBackgroundPublishMarker],
///     [kNegativeSilenceMarker] and [kSessionDisarmedMarker] feed the terminal
///     COMPLETION gate on EVERY leg. Each is printed only after the last
///     assertion of its own phase, and the shell requires all four — without
///     them a `skip: true`, a `markTestSkipped` or an early `return` would let
///     the drive exit 0 having proved nothing (CI_HARDENING_BACKLOG.md A3b).
///   * [kBackgroundReceiveMarker] and [kBackgroundCatchupMarker] are the
///     receive plane's proof, one per plane, and the gate is SYMMETRIC: the
///     live-sync legs require the first and refuse the second, the poll leg
///     requires the second and refuses the first. Each is reachable only from
///     its own compiled branch, so a marker on the wrong leg means the
///     `--dart-define` the drive was built with and the `HAVEN_LIVE_SYNC` the
///     wrapper acted on came from different values.
///   * [kAlwaysSessionMarker] is one more terminal proof, required by the
///     Always leg alone. Without it that leg could exit 0 over a body that
///     never reached the confirmed-Always assertions — the one shape the leg
///     exists for — while the other markers made it look complete.
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
    show
        kLocationPublishMaxInterval,
        kLocationPublishMinInterval,
        kStationaryConfirmMaxAge,
        kStationaryDwell;
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/background_location_provider.dart'
    show backgroundSharingProvider;
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/live_sync_provider.dart'
    show liveSyncEnabled;
import 'package:haven/src/providers/location_provider.dart'
    show locationStreamProvider;
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show kPublishLinkTimeout, locationPublishSchedulerProvider;
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
        iosLocationSourceProvider,
        locationPublishStaggerProvider,
        locationSharingServiceProvider,
        subscriptionServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/background_burst_coordinator.dart'
    show burstBound;
import 'package:haven/src/services/circle_service.dart'
    show Circle, CircleService, DecryptedLocation;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/geolocator_location_service.dart'
    show GeolocatorLocationService;
import 'package:haven/src/services/ios_background_session_service.dart'
    show IosBackgroundSessionService, IosBackgroundSessionStatus;
import 'package:haven/src/services/ios_location_auth_service.dart'
    show IosAuthStatus, MethodChannelIosLocationAuthService;
import 'package:haven/src/services/ios_location_source.dart'
    show IosLocationProfile, IosLocationSource;
import 'package:haven/src/services/live_sync_resubscriber.dart'
    show kLiveSyncRestartBudget;
import 'package:haven/src/services/location_service.dart'
    show LocationPermissionStatus;
import 'package:haven/src/services/location_sharing_service.dart'
    show LocationSharingService, MemberLocation;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:haven/src/services/nostr_subscription_service.dart'
    show NostrSubscriptionService;
import 'package:haven/src/services/subscription_service.dart'
    show SubscriptionServiceException;
import 'package:haven/src/utils/log_alias.dart'
    show LogAliasClass, logAliasHandle, magnitudeBucket;
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
/// One of the five terminal proofs `run-ios-bg-publish.sh`'s completion gate
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

/// Verbatim marker printed only after P2c's last assertion: a peer's kind-445,
/// published while this process was OS-backgrounded, was decrypted by a
/// background burst — and once that burst was over the engine's relay pool held
/// no subscription at all.
///
/// The RECEIVE half of the background promise. P2a/P2b answer "does a
/// backgrounded process still publish"; nothing before this answered "does it
/// still receive, and does it hold anything between the bursts that do".
///
/// Printed by the live-sync legs only, and REFUSED by the poll leg's completion
/// gate: the burst plane it stands for does not exist in a build compiled
/// without the engine, so its presence there would mean the leg was measuring
/// the other plane. [kBackgroundCatchupMarker] is that leg's own proof.
const String kBackgroundReceiveMarker = '[bg-publish] BACKGROUND_RECEIVE_OK';

/// Verbatim marker printed only after P2d's last assertion: the POLL path's
/// 90 s background receive timer ran a catch-up sweep from the OS-backgrounded
/// process, and that sweep landed a peer's kind-445 — published while the
/// process was backgrounded — in the persisted last-known-location store, with
/// the coordinates it was published with.
///
/// The receive half of the background promise on the ROLLBACK configuration.
/// Printed by the `HAVEN_LIVE_SYNC=false` leg only and refused on the others,
/// for the same reason [kBackgroundReceiveMarker] is refused here: the timer is
/// compiled out of a live-sync build (`_startIosBackgroundReceiveTimer` returns
/// on `liveSyncEnabled`), so the two markers are exclusive by construction and
/// the gate treats them that way.
const String kBackgroundCatchupMarker = '[bg-publish] BACKGROUND_CATCHUP_OK';

/// Verbatim marker printed only after P3's silence assertion: over a bounded
/// settle window after `setEnabled(enabled: false)`, the relay-side event-id
/// set for this circle gained nothing created after the disable cutoff.
const String kNegativeSilenceMarker = '[bg-publish] NEGATIVE_SILENCE_OK';

/// Verbatim marker printed only after the final assertion of the whole test:
/// the native handler reported the background session RELEASED after the
/// disable. Printed LAST, so the host also uses it as the signal to
/// re-foreground the app for teardown.
const String kSessionDisarmedMarker = '[bg-publish] SESSION_DISARMED';

/// Verbatim marker printed only after the LAST assertion of the confirmed-
/// Always shape in P1: the tier read back as `always`, the service session is
/// held, `alwaysConfirmed` flipped true, NO `CLBackgroundActivitySession` is
/// held, and the manager is asking for no indicator.
///
/// Required by `run-ios-bg-publish.sh`'s completion gate in the ALWAYS matrix
/// job only — that job is the whole point of the Always tier, so a drive that
/// exited 0 without reaching this line proved nothing about it. The When-In-Use
/// job must NOT print it: the gate would then accept a run that took the Always
/// branch under a WIU grant.
const String kAlwaysSessionMarker = '[bg-publish] ALWAYS_SESSION_OK';

/// Compile-time name of the CoreLocation tier this run is PINNED to.
///
/// Set by `run-ios-bg-publish.sh` from its own `HAVEN_BGP_AUTH_TIER`, which the
/// workflow's matrix supplies, so the grant the host performed and the shape
/// this drive asserts are two readings of ONE value. There is deliberately no
/// default and no fallback to what CoreLocation reports: the tier is an INPUT
/// here, never an observation.
///
/// Branching on the OBSERVED tier instead would be the silent-branch-swap
/// failure this pin exists to prevent. `requestAlwaysAuthorization()` reports
/// `.authorizedAlways` while the second prompt is unanswered, so a simulator
/// that escalated the When-In-Use grant would quietly run the Always shape,
/// pass, and leave the lane measuring something other than what its header
/// says. Pinned, that escalation is a red run that names itself.
const String kExpectedTierDefine = 'HAVEN_BGP_EXPECT_TIER';

/// The raw value of [kExpectedTierDefine]; empty when the define never
/// reached the compiler, which fails the run closed (see [_parseExpectedTier]).
const String _expectedTierRaw = String.fromEnvironment(kExpectedTierDefine);

/// Parses [_expectedTierRaw], or throws with the misconfiguration named.
///
/// Fails CLOSED on an absent or unknown value rather than assuming
/// When-In-Use: a silent default would let the Always matrix job run the
/// When-In-Use assertions and report success for a shape it never exercised.
IosAuthStatus _parseExpectedTier() => switch (_expectedTierRaw) {
  'always' => IosAuthStatus.always,
  'whenInUse' => IosAuthStatus.whenInUse,
  _ => throw StateError(
    '[bg-publish] --dart-define=$kExpectedTierDefine was '
    "${_expectedTierRaw.isEmpty ? 'absent' : "'$_expectedTierRaw'"}; it must "
    "be exactly 'whenInUse' or 'always'. The value is threaded from the "
    "workflow matrix through run-ios-bg-publish.sh's HAVEN_BGP_AUTH_TIER "
    '(when-in-use|always) and run-ios-sim-scenario.sh, and it must match the '
    '`simctl privacy grant` the host performed. Defaulting here would let the '
    'Always job silently run the When-In-Use assertions.',
  ),
};

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

/// Slack added to a burst-link bound whenever the thing being waited for is a
/// kind-445 arriving on THIS drive's own relay subscription rather than a call
/// returning in-process.
///
/// The coordinator's budgets already price the publish itself
/// (`kBurstPublishBudget` is `CONNECTION_TIMEOUT` + `LOCATION_ACK_WINDOW`);
/// what they do not price is strfry storing the event and fanning it out to a
/// second subscriber, plus the event-loop hops on this side. Both are
/// sub-second against a localhost relay. It is deliberately NOT sized from CI
/// run 32661622879's ~0.2 s measurement of a whole tick: that run compiled the
/// receive engine OUT, so its "burst" threw on the first FFI call and measured
/// none of the engine links a burst now runs in front of its publish.
const Duration _relayObservationSlack = Duration(seconds: 15);

/// How long P2b waits for two scheduler-timed post-backgrounding publishes.
///
/// The per-circle scheduler is jittered over `kLocationPublishMinInterval`..
/// [kLocationPublishMaxInterval] (72–168 s), so two consecutive ticks can
/// take up to 2 × 168 s in the worst case; 60 s of slack covers the encrypt
/// + relay round trips on a loaded runner. 396 s total.
final Duration _postBackgroundPublishWindow =
    kLocationPublishMaxInterval * 2 + const Duration(seconds: 60);

/// How long P2c waits for the engine to hold at least one standing
/// subscription while the app is still FOREGROUNDED.
///
/// P2c's control arm, and bounded rather than read once because the circle is
/// created straight through `CircleManagerFfi` and reaches the engine only
/// when the live-sync re-subscriber observes it through `circlesProvider` —
/// after its own debounce, and through an `ensureRunning` that may take the
/// full-restart path. So the window is that path's own bound
/// ([kLiveSyncRestartBudget], itself derived from what the Rust engine allows
/// a stop + start) plus 30 s for the debounce and the FFI hops around it. A
/// run that never reaches one standing REQ inside that is reporting an engine
/// that never subscribed — a lane failure, not a slow runner.
final Duration _standingRequestWindow =
    kLiveSyncRestartBudget + const Duration(seconds: 30);

/// How long P2c waits for a peer's location to reach the in-memory member
/// cache after the tick that should have ingested it has been AWAITED.
///
/// Small on purpose, and the await is what makes it small — but the await is
/// the scheduler's FIFO chain link, not a completion guarantee. It resolves
/// when the burst completes OR when [kPublishLinkTimeout] reports a burst that
/// ran long, which by design cancels nothing. On the ordinary exit the engine
/// has already decrypted the kind-445 in Rust and handed it to the live-event
/// stream, and what is left is Dart-side and local: one `parseEngineLocation`
/// call and one SQLCipher write, serialized behind whatever the router is
/// already processing. 30 s is ~100x that. On the watchdog exit the burst is
/// still running and no window here is the right bound — which is why the
/// drive measures that tick's own wall clock and names it in the failure text,
/// rather than reporting a burst that ran long as an ingest that never
/// happened.
const Duration _peerFixWindow = Duration(seconds: 30);

/// Cadence of the POLL path's background receive timer, mirroring
/// `MapShell._startIosBackgroundReceiveTimer`'s `Timer.periodic`.
///
/// Not importable — that cadence is an inline literal in `map_shell.dart` — so
/// check 16 of `check_ios_background_publish.sh` pins the two together. It has
/// to: a cadence raised there and not here would leave [_pollPathCatchupWindow]
/// spanning ONE tick where its derivation needs two, and the failure of a
/// window that covers the usual case but not the worst one is a FLAKE, not a
/// red.
const Duration _pollPathReceiveInterval = Duration(seconds: 90);

/// The deadline one background catch-up sweep is allowed, from the
/// `maxDurationSecs` default of `CatchupService.runCatchup` — the value
/// `MapShell._runBackgroundCatchUp` takes, since it passes none of its own.
const Duration _pollPathCatchupDeadline = Duration(seconds: 20);

/// How long P2d waits for the poll path's background catch-up to land the
/// peer's location in the PERSISTED last-known store.
///
/// TWO tick intervals, and the second one is a race rather than slack. A sweep
/// whose window opened in the same whole second the peer's event was stored can
/// miss that event and still advance the group cursor to that second — the
/// advance anchor is the local clock read BEFORE the REQ goes out. Nothing
/// recovers it inside that sweep. The NEXT sweep does: every group re-read
/// starts `GROUP_RESUBSCRIBE_BUFFER_SECS` (60 s) BELOW the cursor, which is two
/// orders of magnitude more than the one second at risk. So the answer to that
/// race is one more interval, never a retry of the peer's publish.
///
/// Plus the sweep's own deadline, plus [_relayObservationSlack] for the relay
/// hop, the SQLCipher upsert and this drive's own poll cadence.
final Duration _pollPathCatchupWindow =
    _pollPathReceiveInterval * 2 +
    _pollPathCatchupDeadline +
    _relayObservationSlack;

/// How long P2d's BASELINE read retries before reporting the persisted store
/// empty of the peer.
///
/// A baseline is a single question — "is the row already there?" — and the
/// honest answer to a read that THREW is not "no". 15 s of retries is what
/// stops a transient SQLCipher or FFI hiccup from making the control arm itself
/// the flake, and a healthy run answers on its first read.
const Duration _storeBaselineWindow = Duration(seconds: 15);

/// The sentinel coordinates the peer publishes in P2c / P2d, and the ones the
/// receive plane under test must come to hold — Alice's in-memory member cache
/// on the live-sync legs, her persisted last-known store on the poll one.
///
/// Asserted, not merely counted: a ROW for a pubkey proves a row was written,
/// where the coordinates prove the kind-445 was decrypted and parsed.
///
/// Declared here rather than imported from
/// `e2e/_lib/fake_location_service.dart` (the same numbers live there as
/// `bobFakeLatitude`/`bobFakeLongitude`) because this target must import
/// nothing from the fake-location library: it runs the PRODUCTION location
/// service, and `check_ios_background_publish.sh` check 12 exists to keep it
/// that way. Far from any populated area, hermetic relay only.
const double _peerLatitude = 13.456789;
const double _peerLongitude = 89.876543;

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

/// How long P1's Always run polls for the confirmed-Always shape.
///
/// `CLServiceSession.diagnostics` is an `AsyncSequence`: even the "immediate"
/// first diagnostic of a settled authorization lands AFTER `arm()` returns,
/// and only then does the handler flip `alwaysConfirmed`, re-run `arm()` and
/// drop the activity session. A single read right after the enable is
/// therefore a race, not an oracle. 60 s is far past any main-actor hop; it is
/// sized so that a run which never confirms is reporting a real absence (an
/// iOS 17 runtime, or a provisional grant), never a slow runner.
const Duration _alwaysConfirmWindow = Duration(seconds: 60);

/// Cadence of P1's Always poll, P2b's profile poll and P2c's two engine polls.
///
/// Small enough that P2b's coarse-profile window is sampled ~40 times even if
/// the profile only holds for one escalation cycle, and large enough that the
/// poll's own platform-channel round trips are a rounding error against the
/// work it observes.
const Duration _statusPollInterval = Duration(seconds: 5);

/// How long after the REAL backgrounding P2b polls for the coarse accuracy
/// profile.
///
/// Both terms are the controller's own constants, not chosen numbers.
/// [kStationaryDwell] (120 s) is the stillness the controller requires before
/// it coarsens the session at all — nothing can be observed before it — and
/// [kStationaryConfirmMaxAge] (84 s) is the longest the coarse profile can
/// hold without a confirming fix, i.e. the worst case in which the simulator
/// delivers NOTHING under the 100 m tier and the deadline escalates back to
/// Best. Their sum is therefore the first window in which the drop is
/// guaranteed to be observable whether or not V-P3-1 holds.
final Duration _coarseProfileWindow =
    kStationaryDwell + kStationaryConfirmMaxAge;

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
///
/// [wall] must be the elapsed time of a wait THIS drive bounds — a collect
/// window, a poll deadline — and never of an `await` on production work. The
/// app's own ceilings are larger than every budget passed here
/// ([kPublishLinkTimeout] alone is 180 s), so a wall that spans one would trip
/// this on an app that was executing the whole time and send the reader to
/// `UIBackgroundModes`, the native session handler and P1 for a burst that
/// merely ran long.
void _failIfSuspended(Duration wall, Duration budget, String phase) {
  if (wall <= budget + _suspensionSlack) return;
  fail(
    'iOS SUSPENDED the app during $phase: a ${budget.inSeconds}s wait took '
    '${wall.inSeconds}s of wall clock, so this process was not executing '
    'for ~${(wall - budget).inSeconds}s of it. Nothing measured across that '
    'window says anything about the publish pipeline, and the in-process '
    'oracle cannot measure a frozen process. The keep-alive that should have '
    'prevented this is `UIBackgroundModes: location` plus a LIVE updates '
    "session on `HavenLocationStreamHandler`'s own CLLocationManager, "
    'started with the `allowsBackgroundLocationUpdates` argument its '
    '`onListen` receives (the toggle, verbatim) — so check, in this order: '
    'that P1 above passed (it requires a fresh fix from the REBUILT stream, '
    'which is what proves that session was established while the app was '
    'still in use, and reads the native `status()` back to confirm the '
    'session is running and background-capable), that '
    'HavenBackgroundSessionHandler took the posture its tier calls for, and '
    'that this target still runs the production `GeolocatorLocationService` '
    'and the production native source. The accuracy profile is NOT a '
    'suspect: both profiles keep the shape iOS 16.4 requires of a '
    'continuously-delivering background app (no distance filter, accuracy '
    'never coarser than 100 m), and P2b prints the profile it observed. If '
    'all of the above hold and the process was suspended anyway, the '
    'simulator does not implement the policy and the continuity claim has to '
    'leave CI — see the library doc. Do NOT lengthen the window; it only '
    'trades this attribution for a silent suspension.',
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

/// Returns a Nostr `since` (Unix seconds) that no publish issued BEFORE this
/// call can satisfy, and only once the wall clock has actually reached it.
///
/// `created_at` carries whole seconds, so an anchor taken mid-second cannot
/// separate a publish that has already happened from one this drive is about
/// to cause: both stamp the same second, and `since` is inclusive. Waiting for
/// the clock to leave that second is what makes the two separable at all. It
/// is a wait on this drive's own clock rather than on another actor, so it is
/// bounded by one second by construction; the 20 ms step makes the alignment
/// cost a rounding error of the second it waits out.
Future<int> _anchorAfterCurrentSecond() async {
  final anchor = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 1;
  while (DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 < anchor) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return anchor;
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

/// Polls the native session handler until the CONFIRMED-Always posture holds,
/// or [_alwaysConfirmWindow] expires; returns the last status read.
///
/// The posture is all three at once — the service session held, the diagnostic
/// verdict in, and NO activity session — because each on its own is satisfied
/// by a state the Always job must not accept: a provisional Always holds the
/// service session and never confirms, and an unconfirmed handler holds the
/// activity session (and the pill) exactly as it does under When-In-Use.
Future<IosBackgroundSessionStatus> _pollForConfirmedAlways(
  IosBackgroundSessionService service,
) async {
  var waited = Duration.zero;
  var status = await service.status();
  while (waited < _alwaysConfirmWindow) {
    if (status.alwaysConfirmed &&
        status.serviceSessionHeld &&
        !status.backgroundActivitySessionHeld) {
      return status;
    }
    await Future<void>.delayed(_statusPollInterval);
    waited += _statusPollInterval;
    status = await service.status();
  }
  return status;
}

/// What P2b's bounded profile poll saw.
class _ProfileObservation {
  const _ProfileObservation({
    required this.coarseSeen,
    required this.polls,
    required this.seen,
    required this.wall,
  });

  /// Whether the session was ever observed running at
  /// [IosLocationProfile.hundredMeters] inside the window.
  final bool coarseSeen;

  /// How many status reads the poll made — printed so a run that observed one
  /// value is distinguishable from a run that never got to ask.
  final int polls;

  /// Every profile the poll observed, in the order first seen.
  final List<IosLocationProfile> seen;

  /// Wall clock the poll actually consumed. Compared against its own budget
  /// before its verdict is trusted: a frozen isolate observes nothing for
  /// reasons that have nothing to do with the accuracy tier.
  final Duration wall;
}

/// Polls the native updates session for the coarse accuracy profile, from the
/// backgrounded process, until [deadline].
///
/// A bounded poll and never a single read: even when the simulator delivers
/// nothing under the 100 m tier, the controller's [kStationaryConfirmMaxAge]
/// deadline escalates back to Best, so the coarse profile is a WINDOW rather
/// than a steady state and one sample is a coin flip.
///
/// Reads `status()` on the native handler, which reports the live
/// `manager.desiredAccuracy` — the value CoreLocation is actually running
/// under, not a Dart field mirroring an intent.
Future<_ProfileObservation> _pollForCoarseProfile(
  IosLocationSource source,
  DateTime deadline,
) async {
  final startedAt = DateTime.now();
  final seen = <IosLocationProfile>[];
  var polls = 0;
  var coarseSeen = false;
  while (DateTime.now().isBefore(deadline)) {
    final status = await source.status();
    polls += 1;
    if (!seen.contains(status.profile)) seen.add(status.profile);
    if (status.profile == IosLocationProfile.hundredMeters) {
      coarseSeen = true;
      // wireName (`ios_location_source.dart`) is a fixed enum tag, an alias
      // for `.name` used on the platform-channel wire — not user data.
      // harness-log-ok: see above
      debugPrint(
        '[bg-publish] backgrounded accuracy profile: '
        '${status.profile.wireName} after '
        '${DateTime.now().difference(startedAt).inSeconds}s of polling '
        '(poll #${magnitudeBucket(polls)}).',
      );
      break;
    }
    await Future<void>.delayed(_statusPollInterval);
  }
  return _ProfileObservation(
    coarseSeen: coarseSeen,
    polls: polls,
    seen: seen,
    wall: DateTime.now().difference(startedAt),
  );
}

/// What one of P2c's bounded engine-pool polls saw.
class _PoolObservation {
  const _PoolObservation({
    required this.matched,
    required this.polls,
    required this.last,
    required this.wall,
  });

  /// Whether the poll's verdict is the one its caller wanted.
  ///
  /// What that verdict IS depends on the caller's `decideOnFirstAnswer`: with
  /// it set the verdict is the engine's first ANSWER and nothing later can
  /// change it; without it, the poll waits for `wanted` to come true.
  final bool matched;

  /// How many counts the poll actually read — printed so a run that never got
  /// an answer is distinguishable from one that got the wrong answer.
  final int polls;

  /// The last count read, or `null` when every read threw.
  final int? last;

  /// Wall clock the poll consumed. Compared against its own budget before its
  /// verdict is trusted: a frozen isolate observes nothing for reasons that
  /// have nothing to do with the engine.
  final Duration wall;
}

/// Reads the engine's pool-subscription count until [wanted] holds or [budget]
/// expires, or — with [decideOnFirstAnswer] — until the engine ANSWERS once.
///
/// A read that THROWS never satisfies the poll and never ends it, under either
/// mode. The FFI answers an error when there is no live session, and "there is
/// nothing to ask" must not be readable as "no standing REQ" — zero is the
/// PASSING value of the promise this measures, so a session-less read has to
/// keep the poll running until its own deadline and then report the absence.
/// The budget is what a THROWING read is given, never what a wrong answer is.
///
/// ## Why "the first answer" is a mode at all
///
/// A poll that ends on the first read satisfying [wanted] can only assert
/// "this value was observed AT LEAST ONCE in the window", and for the
/// between-bursts claim that is not the promise: the engine manufactures a
/// zero at the START of every burst that follows a LEAKED pause, because
/// `resume_burst` flushes `unsubscribe_all` before `connect()` +
/// `wait_for_connection` + `register_and_subscribe`. So a run whose pause
/// dropped nothing reads non-zero for the whole gap, then reads zero for
/// several seconds while the next burst opens — and a "was it ever zero" poll
/// goes green on exactly the regression it exists to catch. Deciding on the
/// first answer removes that window entirely: the read is taken with the
/// burst's own teardown already awaited, before any later burst can open one.
///
/// The other direction — "wait for it to come true" — stays available and is
/// what the FOREGROUND control arm needs: there the engine legitimately takes
/// time to subscribe at all (the re-subscriber's debounce, then a possible
/// full restart), and a first-answer read would report an absence that is
/// merely early.
///
/// Each read is bounded by the poll's own remaining budget, so a read that
/// hangs inside the FFI is subject to the deadline like every other term
/// rather than outliving it.
Future<_PoolObservation> _pollPoolSubscriptions(
  NostrSubscriptionService engine,
  Duration budget, {
  required bool Function(int count) wanted,
  required bool decideOnFirstAnswer,
}) async {
  final startedAt = DateTime.now();
  final deadline = startedAt.add(budget);
  var polls = 0;
  int? last;
  var matched = false;
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) break;
    try {
      final count = await engine.poolSubscriptionCount().timeout(remaining);
      polls += 1;
      last = count;
      matched = wanted(count);
      if (matched || decideOnFirstAnswer) break;
    } on Object catch (e) {
      // Rule 8: the type only. Either there is no session yet or the read
      // failed; neither is an answer, and both must keep polling.
      debugPrint('[bg-publish] pool count read failed: ${e.runtimeType}');
    }
    await Future<void>.delayed(_statusPollInterval);
  }
  return _PoolObservation(
    matched: matched,
    polls: polls,
    last: last,
    wall: DateTime.now().difference(startedAt),
  );
}

/// Polls the app's member-location cache for [senderPubkeyHex]'s fix in
/// [circle], until it lands or [budget] expires.
///
/// Reads `LocationSharingService.cachedLocations` — the same in-memory cache
/// `memberLocationsProvider` renders from, and the one the live-event router
/// writes on every decrypted kind-445. Deliberately NOT that provider: a
/// provider REBUILD is deferred to `markNeedsBuild` and frame production is off
/// from the paused transition onwards, so an invalidated provider would never
/// recompute (see the library doc). The cache itself survives this branch's
/// pause — `onAppPaused()`, which drops it, is skipped on iOS with background
/// sharing on.
///
/// Each read is bounded by the poll's own remaining budget, for the reason
/// [_pollPoolSubscriptions]'s are: a read that hangs inside SQLCipher or the
/// FFI must be subject to the deadline rather than outliving it.
Future<({MemberLocation? fix, int polls, Duration wall})> _pollForPeerFix(
  LocationSharingService sharing,
  Circle circle,
  String senderPubkeyHex,
  Duration budget,
) async {
  final startedAt = DateTime.now();
  final deadline = startedAt.add(budget);
  final wanted = senderPubkeyHex.toLowerCase();
  var polls = 0;
  MemberLocation? fix;
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) break;
    try {
      final cached = await sharing.cachedLocations(circle).timeout(remaining);
      polls += 1;
      for (final member in cached) {
        if (member.pubkey.toLowerCase() == wanted) {
          fix = member;
          break;
        }
      }
      if (fix != null) break;
    } on Object catch (e) {
      // Rule 8: the type only — a cache read reaches SQLCipher and the FFI.
      debugPrint('[bg-publish] cached-location read failed: ${e.runtimeType}');
    }
    await Future<void>.delayed(_statusPollInterval);
  }
  return (
    fix: fix,
    polls: polls,
    wall: DateTime.now().difference(startedAt),
  );
}

/// What one of P2d's bounded reads of the persisted last-known store saw.
class _StoredFixObservation {
  const _StoredFixObservation({
    required this.fix,
    required this.polls,
    required this.wall,
  });

  /// The peer's persisted row, or `null` if none ever appeared.
  final DecryptedLocation? fix;

  /// How many reads the poll made — printed so a run that never got to ASK is
  /// distinguishable from one that asked and was answered nothing.
  final int polls;

  /// Wall clock the poll consumed. Compared against its own budget before its
  /// verdict is trusted: a frozen isolate observes nothing for reasons that
  /// have nothing to do with the catch-up sweep.
  final Duration wall;
}

/// Polls the PERSISTED last-known-location store for [senderPubkeyHex]'s row in
/// the circle named by [nostrGroupId], until it lands or [budget] expires.
///
/// The store and NOT `LocationSharingService.cachedLocations`, because on the
/// poll path the writer is a different one. There is no live-event router: the
/// catch-up sweep decrypts in Rust and `persist_locations` upserts one
/// `last_known_location` row per location application message, and nothing
/// hydrates that row into the Dart cache while the app is paused —
/// `cachedLocations` re-reads the store only for a circle it has not hydrated,
/// and this circle was hydrated in the foreground. Reading the cache here would
/// therefore report an absence for a sweep that worked perfectly.
///
/// Each read is bounded by the poll's own remaining budget, for the reason
/// [_pollPoolSubscriptions]'s are: a read that hangs inside SQLCipher or the
/// FFI must be subject to the deadline rather than outliving it.
Future<_StoredFixObservation> _pollForStoredPeerFix(
  CircleService circleService,
  List<int> nostrGroupId,
  String senderPubkeyHex,
  Duration budget,
) async {
  final startedAt = DateTime.now();
  final deadline = startedAt.add(budget);
  final wanted = senderPubkeyHex.toLowerCase();
  var polls = 0;
  DecryptedLocation? fix;
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) break;
    try {
      final rows = await circleService
          .snapshotLastKnownForCircle(nostrGroupId: nostrGroupId)
          .timeout(remaining);
      polls += 1;
      for (final row in rows) {
        if (row.senderPubkey.toLowerCase() == wanted) {
          fix = row;
          break;
        }
      }
      if (fix != null) break;
    } on Object catch (e) {
      // Rule 8: the type only — the read reaches SQLCipher and the FFI.
      debugPrint('[bg-publish] last-known read failed: ${e.runtimeType}');
    }
    await Future<void>.delayed(_statusPollInterval);
  }
  return _StoredFixObservation(
    fix: fix,
    polls: polls,
    wall: DateTime.now().difference(startedAt),
  );
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

      // The tier this run is pinned to, resolved BEFORE the ~5 min of harness
      // setup so a missing define fails in the first second and names itself
      // rather than after a build, a boot and a circle creation.
      final expectedTier = _parseExpectedTier();
      debugPrint(
        '[bg-publish] pinned CoreLocation tier: ${expectedTier.name} '
        '(from --dart-define=$kExpectedTierDefine).',
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
            scenario: 'bg-publish',
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
            .eligibleKeysForTest
            .isNotEmpty,
        description:
            'the per-circle publish scheduler armed a scheduler for the new '
            'circle (proof it is publish-eligible BEFORE the backgrounding)',
        timeout: const Duration(seconds: 60),
      );

      final groupIdHex = bytesToHex(creation.circle.nostrGroupId);

      // The app's own model of the circle, captured while frames still run.
      // P2c reads the member-location cache through it after the pause, where
      // `circlesProvider` could no longer recompute if anything invalidated it.
      final matchingCircles =
          (container.read(circlesProvider).valueOrNull ?? const <Circle>[])
              .where((c) => bytesToHex(c.nostrGroupId) == groupIdHex)
              .toList(growable: false);
      if (matchingCircles.length != 1) {
        throw StateError(
          '[bg-publish] circlesProvider carries '
          '${magnitudeBucket(matchingCircles.length)} circles with this '
          "test's group id, although the publish scheduler armed for it — "
          'so P2c has no single handle to read the member-location cache '
          'through.',
        );
      }
      final aliceCircle = matchingCircles.single;

      // Bob stays ALIVE across the pause, which P2a/P2b can afford because he
      // publishes only when this drive tells him to: `SyntheticUser` runs no
      // timer of its own, so nothing of his lands in the `#h` scope P2a/P2b
      // attribute to the app. P2c/P2d are what need him — a peer that publishes
      // WHILE Alice is backgrounded is the only way to ask whether her receive
      // plane still works — and his `dispose()` deletes the data directory his
      // `CircleManagerFfi` encrypts with, so it must happen after his last
      // publish and before P3 starts attributing every new event to the app.
      //
      // The drive's own relay socket outlives the pause either way: it is the
      // P2/P3 wire oracle.

      // The FOREGROUND reading of the engine's standing-subscription count. It
      // serves BOTH legs, and it is what makes them tell themselves apart:
      //
      //   live-sync — it is P2c's control arm. Zero is the value P2c's promise
      //     is KEPT by, so the counter has to be shown to be one this engine
      //     can move OFF; without it, "no standing REQ between bursts" would
      //     pass on an engine that never subscribed to anything.
      //   poll — the same read must FAIL, with the null-handle refusal
      //     specifically. That is not a weaker assertion, it is the LEG'S
      //     IDENTITY: `poolSubscriptionCount` throws when there is no session
      //     (it deliberately never answers 0 for one), and no session is
      //     exactly why P2c cannot exist on this leg — and it is the premise
      //     P2d's attribution rests on, which is why the matcher below pins
      //     WHICH throw.
      //
      // What it does NOT catch, said here because an earlier version of this
      // comment claimed it did: a leg whose wrapper env said `false` while the
      // build compiled the engine in. This branch is selected by the same
      // compiled `liveSyncEnabled` the app uses, so in that mismatch the drive
      // takes the live-sync arm above and never reaches here. The wrapper's
      // completion gate is what refuses that shape — BACKGROUND_RECEIVE_OK in
      // a flag-off log, and the mirror.
      final subscriptions = container.read(subscriptionServiceProvider);
      if (subscriptions is! NostrSubscriptionService) {
        throw StateError(
          '[bg-publish] subscriptionServiceProvider is not the Rust-backed '
          'service in this run, so the live-sync engine this lane now measures '
          'was replaced by something else.',
        );
      }
      int? foregroundStanding;
      if (liveSyncEnabled) {
        final foregroundPool = await _pollPoolSubscriptions(
          subscriptions,
          _standingRequestWindow,
          wanted: (count) => count > 0,
          // The one call that legitimately WAITS for the count to change: the
          // engine has not necessarily subscribed to anything yet, so an early
          // zero here is not an answer about the promise, it is an answer about
          // the re-subscriber's debounce.
          decideOnFirstAnswer: false,
        );
        foregroundStanding = foregroundPool.last;
        debugPrint(
          '[bg-publish] foreground standing subscriptions: '
          '${magnitudeBucket(foregroundStanding ?? 0)} after '
          '${magnitudeBucket(foregroundPool.polls)} read(s).',
        );
        expect(
          foregroundPool.matched,
          isTrue,
          reason:
              'The live-sync engine holds NO standing subscription while the '
              'app is foregrounded with an accepted circle (last count: '
              '${magnitudeBucket(foregroundStanding ?? 0)}, '
              '${magnitudeBucket(foregroundPool.polls)} read(s) over '
              '${_standingRequestWindow.inSeconds}s). Two causes are real and '
              'both invalidate P2c rather than merely failing here: this build '
              'was compiled with HAVEN_LIVE_SYNC=false, so there is no '
              'receive engine to burst at all (a session-less read throws, and '
              'the poll reports it as an absence) — that is the POLL leg, '
              'and it must not reach this branch; or the re-subscriber never '
              'observed the circle through circlesProvider. Nothing below may '
              'be read as '
              '"the burst holds no standing REQ" until this passes: a counter '
              'that is always zero proves that claim for free.',
        );
      } else {
        Object? readError;
        int? readCount;
        try {
          readCount = await subscriptions.poolSubscriptionCount();
        } on Object catch (e) {
          // Rule 8: the type only — the FFI message is a Rust `Result` string.
          readError = e;
        }
        final readCountBucket = readError == null
            ? 'answered ${magnitudeBucket(readCount ?? 0)}'
            : 'failed with ${readError.runtimeType}';
        debugPrint(
          '[bg-publish] HAVEN_LIVE_SYNC=false leg: the pool count read '
          '$readCountBucket.',
        );
        expect(
          readError,
          // WHICH throw, not merely that one happened. The service raises two
          // different `SubscriptionServiceException`s here and they mean
          // OPPOSITE things: `no active live session` is the null-handle check
          // AHEAD of the FFI — this leg's identity — while `failed to read the
          // pool subscription count` comes from inside the try, i.e. only when
          // the service HELD an engine handle and the read failed anyway (a
          // cleared Rust SESSION, a poisoned lock, a panic, an uninitialised
          // bridge). A bare `isNotNull` accepted the second one, and with it a
          // build in which a session existed — the state this branch exists to
          // refute, and the premise P2d's "nothing else could have written
          // that row" rests on.
          isA<SubscriptionServiceException>().having(
            (SubscriptionServiceException e) => e.message,
            'message',
            'no active live session',
          ),
          reason:
              'This build was compiled with HAVEN_LIVE_SYNC=false — the branch '
              'you are reading only runs when it was — yet the read did not '
              'report an ABSENT session. Either it answered a count '
              '(${magnitudeBucket(readCount ?? 0)}), or it threw something '
              'other than the null-handle '
              'refusal; both say a live session exists in a build whose flag '
              'documents that the engine is never started. Three causes, in '
              'the order to check them. (1) Something started one anyway. '
              '`MapShell._healLiveSyncIfStopped` returns early on '
              '`!liveSyncEnabled` and is the single door every engine start in '
              'the app goes through, so a session here means either that gate '
              'was removed or a NEW start path was added beside it — the '
              'rollback path would then not be the path a rolled-back build '
              'runs. (2) The read threw `failed to read the pool subscription '
              'count`: that message is raised from INSIDE the try, so the '
              'service was holding an engine handle and the FFI failed as '
              'well — cause (1) plus a broken read, not a milder version of '
              'it. (3) The wrapper acted on HAVEN_LIVE_SYNC=false while the '
              'build never got the matching --dart-define — but that shape '
              'prints BACKGROUND_RECEIVE_OK from the other branch and the '
              'completion gate already refuses it on this leg, so it is not '
              'what this read catches. Never relax this to accept a live '
              'session, or to accept any throw: it is the observable '
              'statement of WHY P2c cannot run on this leg, and the premise '
              "P2d's attribution argument below rests on.",
        );
      }

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

      // The tier PIN. Read from real CoreLocation through the production
      // bridge, and read AFTER the enable because `setEnabled(enabled: true)`
      // is what issues the "Always" escalation request — the one call that can
      // turn a When-In-Use grant into the provisional Always this must catch.
      final observedTier = await const MethodChannelIosLocationAuthService()
          .checkStatus();
      debugPrint(
        '[bg-publish] observed CoreLocation tier: ${observedTier.name}',
      );
      expect(
        observedTier,
        expectedTier,
        reason:
            'This run was pinned to ${expectedTier.name} but CoreLocation '
            'reports ${observedTier.name}. A tier flip is a RED run on '
            'purpose: under ${expectedTier.name} the assertions below describe '
            'a different session posture, so a silent swap would leave the '
            'lane green while measuring something other than what its header '
            'says. Under a When-In-Use grant the likely cause is the '
            'simulator honouring the "Always" escalation request this enable '
            'issued and reporting a PROVISIONAL Always (authorizationStatus '
            'answers .authorizedAlways while the second prompt is '
            'unanswered). Fix the grant in run-ios-bg-publish.sh or the '
            'matrix tier — never relax this to accept either value.',
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

      // The tier→policy mapping, which is what OD1 and OD-P3-b rest on. It is
      // asserted per tier and inverted between them, so a handler that took
      // one posture unconditionally cannot satisfy both jobs.
      if (expectedTier == IosAuthStatus.whenInUse) {
        expect(
          armedStatus.backgroundActivitySessionHeld,
          isTrue,
          reason:
              'Background sharing was enabled through the production '
              'setEnabled path under a When-In-Use grant, but '
              'HavenBackgroundSessionHandler holds no '
              'CLBackgroundActivitySession. Without it, a When-In-Use app has '
              'no supported claim to background location delivery on modern '
              'iOS — the keep-alive contract this lane exists to pin is '
              'unarmed, and this is the posture the 2026-08-20 field failure '
              'was missing.',
        );
        debugPrint(
          '[bg-publish] status after arm: held=true '
          'serviceSessionHeld=${armedStatus.serviceSessionHeld} '
          'alwaysConfirmed=${armedStatus.alwaysConfirmed}',
        );
      } else {
        // Under a FULL "Always" grant the handler must reach the confirmed
        // posture: the .always service session held, the diagnostic verdict
        // in, and the activity session (with it, the blue bar) gone. The
        // verdict is ASYNCHRONOUS — it lands after `arm()` returns and only
        // then does the re-run drop the activity session — so this is a
        // bounded poll, never a single read.
        final confirmed = await _pollForConfirmedAlways(sessionService);
        debugPrint(
          '[bg-publish] status after arm: '
          'held=${confirmed.backgroundActivitySessionHeld} '
          'serviceSessionHeld=${confirmed.serviceSessionHeld} '
          'alwaysConfirmed=${confirmed.alwaysConfirmed}',
        );
        expect(
          confirmed.alwaysConfirmed,
          isTrue,
          reason:
              '"Always" was granted, but no CLServiceSessionDiagnostic '
              'confirmed it within ${_alwaysConfirmWindow.inSeconds}s, so the '
              'handler is still on the fail-safe When-In-Use posture. Two '
              'causes are real and neither is fixed here: the runtime is '
              'iOS 17 (no diagnostics API — the Always job needs iOS 18+, so '
              'raise the runner image), or the grant is PROVISIONAL. Do not '
              'weaken this: an unconfirmed Always is exactly the cohort '
              'OD-P3-b keeps on the When-In-Use shape.',
        );
        expect(
          confirmed.serviceSessionHeld,
          isTrue,
          reason:
              '"Always" was granted and confirmed, but the handler holds no '
              'CLServiceSession(.always). Since iOS 18 an Always '
              'authorization is only effective while that session is held, so '
              'without it the confirmed-Always shape has no authorization to '
              'run on at all.',
        );
        expect(
          confirmed.backgroundActivitySessionHeld,
          isFalse,
          reason:
              'Under a CONFIRMED "Always" the CLBackgroundActivitySession '
              'must be released: it is inseparable from the blue location '
              'bar, and OD1 is the decision that a confirmed-Always user sees '
              'the OS arrow instead. A handler that keeps holding it has '
              'either not re-run arm() on the confirmation or has lost the '
              'tier branch — and the WHOLE point of this matrix job is the '
              'shape with no activity session held.',
        );
      }

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

      // What the NATIVE updates session says it is doing, read back over the
      // same channel the app uses. The fresh fix above proves a session is
      // delivering; this proves it is the session iOS will keep running once
      // the app is backgrounded — and it is the only in-process reading of
      // `manager.allowsBackgroundLocationUpdates` and `desiredAccuracy` that
      // exists, since nothing runs Swift unit tests in CI.
      final iosSource = container.read(iosLocationSourceProvider);
      final streamStatus = await iosSource.status();
      expect(
        streamStatus.running,
        isTrue,
        reason:
            'HavenLocationStreamHandler reports no running updates session '
            'after the background-sharing flip rebuilt the position stream, '
            'even though a fresh fix arrived. The status read is failing '
            'closed (an unreachable handler answers `unknown`), so treat this '
            'as the channel being wrong rather than the session being absent: '
            'check that the handler is registered under '
            '`haven.app/ios_location_stream`.',
      );
      expect(
        streamStatus.allowsBackgroundLocationUpdates,
        isTrue,
        reason:
            'The running CLLocationManager session is NOT background-capable. '
            "It is the app's only claim to keep executing once iOS "
            'backgrounds it, iOS only lets such a session START while the app '
            'is in use, and this is the last moment that can be checked — so '
            'P2 would go on to measure a suspended process. The flag is a '
            'pure function of the background-sharing toggle, passed as the '
            'listen argument.',
      );
      expect(
        streamStatus.profile,
        IosLocationProfile.best,
        reason:
            'A FOREGROUNDED session must run at the Best profile: somebody is '
            'looking at the map, and only Best-profile fixes are ever '
            'published. A coarse profile here means the controller coarsened '
            "without a backgrounding, which would also make P2b's window "
            'meaningless (it measures the drop that follows one).',
      );
      expect(
        streamStatus.backgrounded,
        isFalse,
        reason:
            'The native lifecycle read says this process is already '
            'backgrounded, before the host has been asked to background it. '
            'That read is fail-closed (an unreadable status answers '
            '"backgrounded"), so this is either a broken status channel or a '
            'launch this drive did not observe — and everything P2 attributes '
            'to the backgrounding would be attributed wrongly.',
      );
      // The indicator is where the two tiers visibly differ, and it is chosen
      // by the handler's own confirmed-Always state, never by the raw
      // authorization. Under When-In-Use the OS shows the bar regardless, so
      // asking for it is documentation-honest; under a CONFIRMED Always the
      // flag is the only remaining source of a bar, and OD1 is the decision
      // that there is none.
      expect(
        streamStatus.showsBackgroundLocationIndicator,
        expectedTier == IosAuthStatus.whenInUse,
        reason:
            expectedTier == IosAuthStatus.whenInUse
            ? 'Under When-In-Use the manager must ask for the background '
                  'location indicator. The OS shows it either way there, so a '
                  'false flag is not a privacy leak — it is a copy lie: the '
                  'settings page picks its indicator sentence from this same '
                  'handler state, and would promise an arrow the user does '
                  'not have.'
            : 'Under a CONFIRMED "Always" the manager must NOT ask for the '
                  'background location indicator (OD1: the OS arrow and the '
                  'Settings attribution are the signals, and the constant '
                  'blue bar is what P3 removes). A true flag here is the '
                  'un-applied indicator policy — the handler confirmed Always '
                  'but never re-applied it.',
      );
      // Printed only under Always, and only after the last assertion that
      // establishes the confirmed-Always shape. The When-In-Use job must not
      // reach it: its completion gate does not accept it, and the Always job's
      // does.
      if (expectedTier == IosAuthStatus.always) {
        debugPrint(kAlwaysSessionMarker);
      }

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

        // The backgrounding instant. [_coarseProfileWindow] is measured from
        // it because the controller starts its stationary dwell on the same
        // transition MapShell just relayed through `foregroundActive = false`;
        // P3's relay snapshots are scoped to it so the circle-creation traffic
        // published minutes ago is out of their diff. Every OTHER window below
        // is measured from its own phase, and P2a's anchor is taken later
        // still (see there).
        final backgroundedAt = DateTime.now();
        final backgroundedSecs =
            backgroundedAt.toUtc().millisecondsSinceEpoch ~/ 1000;

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

        // The PROFILE oracle, started HERE — at the transition its window is
        // measured from — and polled concurrently with everything below.
        // [_coarseProfileWindow] is the controller's own dwell plus its
        // confirm deadline, i.e. an interval that begins when the app is
        // backgrounded; started after a publish phase instead, it is whatever
        // that phase left of it, and a phase that ran long reports "the tier
        // never engaged" for a poll that made no reads. It is what makes the
        // power claim checkable in CI at all: the tier has to be REQUESTED on
        // the live CLLocationManager, not merely written to a Dart field, and
        // the only way to see that is to ask the native handler what
        // `manager.desiredAccuracy` is while the app is backgrounded.
        //
        // A POLL rather than a read: the coarse profile is a window, not a
        // steady state, whenever the simulator delivers nothing usable under
        // the 100 m tier (the confirm deadline then escalates back to Best
        // every 84 s). See the library doc's V-P3-1 note for the one outcome
        // that would retire this oracle — and for why the answer to it is
        // never a longer window.
        final profileFuture = _pollForCoarseProfile(
          iosSource,
          backgroundedAt.add(_coarseProfileWindow),
        );

        // The coordinator's own bound on the links a ONE-circle burst runs up
        // to and including its publish: the connect wait, the backlog wait,
        // the single one-shot GPS window a burst shares, and the
        // single-attempt location publish. This lane has exactly one circle
        // (asserted below), so the decorrelation term — which `burstBound`
        // sums over gaps 2..n — is empty.
        final oneCircleBurstBound = burstBound(
          1,
          container.read(locationPublishStaggerProvider),
        );

        // =================================================================
        // P2a — the publish PIPELINE works from a process iOS has genuinely
        // backgrounded, established from ONE tick this drive causes rather
        // than inferred from a 396 s silence.
        //
        // `triggerTickForTest` enqueues onto the production chain exactly as
        // the jittered timer does — same `_onCircleTick`, same `_active`
        // gate, same sink dispatch, same `publishInBurst` — and resolves when
        // that link has run; only the timer is bypassed, and
        // `JitteredScheduler` owns the re-arm, so P2b's independent timers
        // are untouched. It separates the two questions P2 used to conflate:
        // "can this process still publish at all" from "does iOS keep it
        // running long enough to publish twice" (P2b, answerable only if the
        // keep-alive works).
        //
        // TWO publishers can put a kind-445 on this circle's wire in the
        // seconds after the transition, and only one of them is P2a's
        // subject. `MapShell._onPaused` drives a burst AT the pause instant
        // whenever the last publish is null or outside
        // `kLocationPublishOverlapGuard` — synchronously, inside the
        // lifecycle dispatch, so that burst is already on the coordinator's
        // chain before this drive's 250 ms poll has even seen the pause.
        // Anchored at the transition, P2a's collect is satisfied by THAT
        // burst's publish and the tick this phase drives goes unasserted.
        //
        // So the anchor is taken after it. `burstBound` is the whole interval
        // in which a pause-driven publish can appear — it is the coordinator's
        // own budget for those links, and the coordinator REPORTS an overrun
        // of it — so a collect that comes back empty across it means the pause
        // took `closeIdle()` instead (nothing was eligible, or the last
        // publish was still inside the overlap guard), not that a publish is
        // still coming. Either way, what follows the wait is attributable.
        // =================================================================
        final pausePublishWindow =
            oneCircleBurstBound + _relayObservationSlack;
        // Past the transition SECOND, not merely past the transition: a
        // foreground tick that published in the same whole second the host
        // backgrounded the app would otherwise end this wait at once and put
        // the anchor back in front of the pause-driven burst. Excluding a
        // pause-driven publish that also lands in that second costs nothing —
        // this collect then finds nothing, times out, and the anchor taken
        // afterwards is later still.
        final pauseSinceSecs = await _anchorAfterCurrentSecond();
        var pausePublishing = true;
        final pausePublishFuture = relay
            .collectN(
              count: 1,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': pauseSinceSecs,
              },
              timeout: pausePublishWindow,
            )
            .whenComplete(() => pausePublishing = false);
        final pausePublishHeartbeat = _heartbeatWhile(
          () => pausePublishing,
          pausePublishWindow,
          'the publish the pause itself drove, so P2a can anchor past it',
        );
        final pauseDrivenEvents = await pausePublishFuture;
        await pausePublishHeartbeat;
        debugPrint(
          '[bg-publish] pause-driven publishes seen before the P2a anchor: '
          '${magnitudeBucket(pauseDrivenEvents.length)}.',
        );

        // From the tick to its kind-445 on the wire, every term a budget the
        // app itself enforces:
        //
        //   * the tick queues on the coordinator's chain behind whatever the
        //     pause started — this circle is in that burst's `_encrypted` set
        //     the moment it publishes, so the tick can only queue, never join
        //     — and what that burst still owes once its publish has been seen
        //     is its teardown: [kOptOutBurstWait], the settle cap plus the
        //     four bounded lifecycle ops of the pause plus the single-attempt
        //     publish it may be inside;
        //   * then the driven burst's own links, `oneCircleBurstBound`;
        //   * plus [_relayObservationSlack] for the wire hop this drive sees
        //     it over.
        //
        // What no term prices is a maintenance fold between the two, and
        // `burstBound`'s own doc says why: a due fold publishes through the
        // commit ladder and no honest bound on a whole burst exists. The
        // KeyPackage deadline is 10 minutes and this lane is backgrounded for
        // longer than that, so a fold landing HERE is possible and would
        // report as a P2a timeout rather than as itself — which is why the
        // failure text names it first.
        final drivenPublishWindow =
            kOptOutBurstWait + oneCircleBurstBound + _relayObservationSlack;
        final drivenSinceSecs = await _anchorAfterCurrentSecond();

        var driving = true;
        final drivenStartedAt = DateTime.now();
        // Stamped inside `whenComplete`, so the wall this drive judges is the
        // COLLECT's — the one term it bounds itself. Measured to the end of
        // the awaited tick instead, it spans `kPublishLinkTimeout` — which is
        // larger than the sum above, so a burst that merely ran long would be
        // reported as an OS suspension.
        Duration? drivenCollectWall;
        final drivenFuture = relay
            .collectN(
              count: 1,
              filter: <String, dynamic>{
                'kinds': <int>[445],
                '#h': <String>[groupIdHex],
                'since': drivenSinceSecs,
              },
              timeout: drivenPublishWindow,
            )
            .whenComplete(() {
              driving = false;
              drivenCollectWall = DateTime.now().difference(drivenStartedAt);
            });
        final drivenHeartbeat = _heartbeatWhile(
          () => driving,
          drivenPublishWindow,
          'the kind-445 from the per-circle tick driven while backgrounded',
        );
        final drivenTickStartedAt = DateTime.now();
        await container
            .read(locationPublishSchedulerProvider.notifier)
            .triggerTickForTest();
        final drivenTickWall = DateTime.now().difference(drivenTickStartedAt);
        final drivenEvents = await drivenFuture;
        await drivenHeartbeat;

        _failIfSuspended(
          drivenCollectWall!,
          drivenPublishWindow,
          'P2a (the driven backgrounded publish)',
        );
        expect(
          drivenEvents,
          isNotEmpty,
          reason:
              'A per-circle publish tick driven through the production '
              'scheduler from an OS-backgrounded process put no kind-445 for '
              'this circle on the relay within '
              '${drivenPublishWindow.inSeconds}s (the tick itself returned '
              'after ${drivenTickWall.inSeconds}s). Check that number first: '
              'at or near ${kPublishLinkTimeout.inSeconds}s the chain '
              'watchdog reported the burst and returned while it was still '
              'running, so the likely cause is a due KeyPackage or relay-list '
              'fold on the commit ladder — a term no window here prices — and '
              'not the pipeline. Well below it, the tick completed and the '
              'break IS inside the pipeline: the burst opened but never '
              'reached its publish pass, the shared GPS window was refused, '
              'the MLS encrypt failed, or the publish pool did not survive '
              'the backgrounding. P2b below is the separate question of '
              'whether the scheduler keeps FIRING.',
        );
        // Attribution, not decoration. Kind-445 carries commits and proposals
        // as well as application messages, and only the latter get the NIP-40
        // `expiration` tag the engine derives from group component 0x8005 —
        // so a commit auto-published by the engine would satisfy the collect
        // above while proving nothing about the location pipeline. No
        // membership change happens after Bob joins, so none is expected;
        // this is what makes that expectation checked rather than assumed.
        expect(
          drivenEvents.where((e) => e.tag('expiration') == null),
          isEmpty,
          reason:
              'The kind-445 attributed to the driven tick carries no NIP-40 '
              'expiration tag, so it is a commit or a proposal rather than a '
              'location application message. Something published a commit '
              'while this process was backgrounded — the engine auto-publishes '
              'one for a staged roster change — and P2a measured that instead '
              'of the publish pipeline it names.',
        );

        // =================================================================
        // P2b — publishes CONTINUE while OS-backgrounded: ≥2 kind-445 events
        // for this circle from the scheduler's OWN jittered timers.
        //
        // `since` anchors past P2a's driven event so that event cannot count
        // toward the two: the claim is about timers firing, not about this
        // test's ability to call a method. Anchored through
        // [_anchorAfterCurrentSecond] rather than by adding a second to a
        // mid-second reading, because `created_at` is whole seconds and an
        // anchor that has not been REACHED yet excludes nothing.
        // =================================================================
        final timedSinceSecs = await _anchorAfterCurrentSecond();
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
        // Started at the transition and running ever since; awaited HERE
        // because its verdict belongs with P2b's.
        final profile = await profileFuture;
        // wireName (`ios_location_source.dart`) is a fixed enum tag, an
        // alias for `.name` used on the platform-channel wire — not user
        // data.
        // harness-log-ok: see above
        debugPrint(
          '[bg-publish] backgrounded profile poll: coarseSeen='
          '${profile.coarseSeen} polls=${magnitudeBucket(profile.polls)} '
          'seen=${profile.seen.map((p) => p.wireName).toList()} '
          'wall=${profile.wall.inSeconds}s of '
          '${_coarseProfileWindow.inSeconds}s.',
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
        // Same discipline for the profile poll's own budget: a poll that ran
        // long observed nothing because it was not running, which says nothing
        // about the accuracy tier.
        _failIfSuspended(
          profile.wall,
          _coarseProfileWindow,
          'P2b (the backgrounded accuracy-profile poll)',
        );
        // Asserted BEFORE the count, because a session still pinned at Best
        // explains a healthy count perfectly well and would leave the tier
        // claim unproven behind a green lane. Unproven, not unmeasured: no lane
        // in this repo observes energy at all, so what this poll can establish
        // is the MECHANISM — the coarse tier really is requested and really is
        // honoured — and the saving that rides on it stays an estimate
        // (`docs/POWER_EFFICIENCY_PLAN.md` §6.5a (iii)).
        expect(
          profile.coarseSeen,
          isTrue,
          reason:
              'The backgrounded session never ran at '
              '${IosLocationProfile.hundredMeters.wireName} in the '
              '${_coarseProfileWindow.inSeconds}s after the REAL OS '
              'backgrounding (${magnitudeBucket(profile.polls)} status reads; '
              'profiles observed: '
              '${profile.seen.map((p) => p.wireName).toList()}). '
              'That window is kStationaryDwell + kStationaryConfirmMaxAge, so '
              'it covers the drop AND the worst case where nothing confirms '
              'and the deadline escalates straight back to Best. Check, in '
              'this order: that MapShell relayed the pause into '
              'GeolocatorLocationService.foregroundActive (nothing else '
              'starts the dwell), that the drip is still delivering fixes '
              '(the controller only re-decides on a fix or the deadline), and '
              'that setProfile reaches the native handler. If the simulator '
              'turns out never to honour the 100 m tier at all, the answer is '
              'the documented downgrade in the library doc — the host-side '
              'controller proof — never a wider window here.',
        );
        expect(
          events.length,
          greaterThanOrEqualTo(2),
          reason:
              'Only ${magnitudeBucket(events.length)} scheduler-timed '
              'kind-445 event(s) for '
              'this circle reached the relay in the '
              '${_postBackgroundPublishWindow.inSeconds}s after the REAL '
              'OS backgrounding (window = 2 full 72-168s jitter intervals '
              '+ slack, so two ticks MUST fit). P2a proved the pipeline '
              'itself still works from this backgrounded process, so the '
              'per-circle timers stopped firing: the app stopped publishing '
              'when iOS backgrounded it — the regression this lane exists '
              'to catch.',
        );
        // The same attribution P2a takes, and P2b needs it more: two
        // producers other than the per-circle timers can put a kind-445 with
        // this `#h` on the wire — the engine's own auto-published commits,
        // and the peer, who is deliberately kept alive across the pause for
        // P2c. The peer is held out by SEQUENCE (`SyntheticUser` runs no
        // timer of its own and his one publish is driven below, after this
        // collect has resolved); a commit is held out by SHAPE, because only
        // an application message carries the NIP-40 expiration tag. Without
        // this, "the timers kept firing" would be one auto-commit away from
        // passing for the wrong reason.
        expect(
          events.where((e) => e.tag('expiration') == null),
          isEmpty,
          reason:
              'One of the kind-445 events attributed to the per-circle '
              'publish timers carries no NIP-40 expiration tag, so it is a '
              'commit or a proposal rather than a location application '
              'message. The engine auto-publishes a commit for a staged '
              'roster change, and no roster change happens in this run after '
              'Bob joins — so this count is not evidence that the timers kept '
              'firing, whatever its size.',
        );
        debugPrint(
          '$kBackgroundPublishMarker count=${magnitudeBucket(events.length)}',
        );

        // The RECEIVE half, and which plane this build HAS decides which of
        // the two phases below runs. `liveSyncEnabled` is a compile-time
        // const, so the other plane's phase is compiled out along with the
        // plane itself — this is a branch, never a skip, and each arm ends in
        // its own terminal proof so the wrapper's completion gate can tell a
        // branch that ran from one that returned early (A3b).
        if (liveSyncEnabled) {
          // =================================================================
          // P2c — the burst RECEIVES, and holds nothing between bursts.
          //
          // P2a and P2b measure the publish half only. The background receive
          // plane is now a per-tick BURST — open every REQ at its cursor, let
          // the stored replay land, publish, settle, pause — and nothing so far
          // asks whether the ingest half of that survives a real backgrounding,
          // or whether the pause it ends in really drops the subscriptions.
          // Both are asserted here, and each is the other's control:
          //
          //   * a peer's kind-445, published while this process is
          //     OS-backgrounded, must be DECRYPTED into the member cache —
          //     which only a burst that opened, subscribed and ingested can do;
          //   * once that burst is over the pool must hold NO subscription —
          //     read as a COUNT of registered subscriptions, never as the
          //     engine's paused FLAG. The engine raises that flag as the first
          //     statement of its pause, before `unsubscribe_all`, before the
          //     router drain, before the uncapped Rule-13 publish gauge and
          //     before the disconnect, so it reports the pause was ENTERED, not
          //     that anything was dropped. It would have read `true` for every
          //     one of the states this assertion exists to catch.
          //
          // What P2c does NOT prove: that no SOCKET is open between bursts.
          // There is no in-process oracle for that — the count is
          // subscriptions, not connections — and this lane's relay logs no
          // REQ/CLOSE frames, so there is no relay-side oracle either. The
          // socket half is pinned in Rust (`live_sync_burst_e2e.rs`, on relay
          // health), and the honest reading of a green here is "no standing
          // REQ", nothing wider.
          // =================================================================
          //
          // Bob publishes FIRST and the publish is ACKED before the tick is
          // driven, which is what carries the ingest through every ordinary
          // interleaving: a burst opened after the ack replays the event from
          // the relay's store, and a burst already open when the ack lands is
          // still subscribed and is pushed it live.
          //
          // The tick this drive causes normally QUEUES rather than joins, which
          // is the stronger of the two: `onTick` only joins while the running
          // burst has not encrypted this circle yet, and the burst that
          // produced P2b's second event added this circle to `_encrypted`
          // before publishing it. A burst started in the gap between that event
          // landing and the trigger below — a jittered tick, ~1 s of a 72-168 s
          // cadence — would be joined instead, and then the event rides that
          // burst's standing REQ rather than a fresh replay. The one
          // interleaving that loses it is a joined burst whose teardown falls
          // between the relay's broadcast and the engine's socket read:
          // sub-millisecond against a localhost relay, and stated here rather
          // than closed, because closing it means draining the chain with an
          // extra awaited burst and that costs a whole `kPublishLinkTimeout` of
          // the lane's background window.
          final peerEventId = await bob.publishLocation(
            circle: bobCircle,
            latitude: _peerLatitude,
            longitude: _peerLongitude,
            relay: relay,
          );
          debugPrint(
            '[bg-publish] peer published a location while Alice was '
            'backgrounded (evt='
            '${logAliasHandle(LogAliasClass.event, peerEventId)}).',
          );

          // The same production entry point P2a drives, for the same reason:
          // this asks whether a burst RECEIVES, and P2b has already answered
          // whether the timers that start bursts keep firing.
          //
          // Awaited — but the await is the scheduler's FIFO chain link, and
          // `_dispatchTick` wraps every link in `.timeout(kPublishLinkTimeout)`
          // with an `onTimeout` that REPORTS and does not cancel. So it
          // resolves either when the burst has completed its ingest, its pause
          // and its pool close, or when a burst that ran long was reported
          // while still holding all three. The two are not interchangeable for
          // either assertion below, so the wall clock of the await is measured
          // and named in both failure texts rather than assumed away.
          final receiveTickStartedAt = DateTime.now();
          await container
              .read(locationPublishSchedulerProvider.notifier)
              .triggerTickForTest();
          final receiveTickWall = DateTime.now().difference(
            receiveTickStartedAt,
          );
          debugPrint(
            '[bg-publish] the receive tick returned after '
            '${receiveTickWall.inSeconds}s (chain watchdog: '
            '${kPublishLinkTimeout.inSeconds}s).',
          );

          var receiving = true;
          final peerFixFuture = _pollForPeerFix(
            container.read(locationSharingServiceProvider),
            aliceCircle,
            bob.pubkeyHex,
            _peerFixWindow,
          ).whenComplete(() => receiving = false);
          final receiveHeartbeat = _heartbeatWhile(
            () => receiving,
            _peerFixWindow,
            "the peer's location to be decrypted by a background burst",
          );
          final peerFix = await peerFixFuture;
          await receiveHeartbeat;

          _failIfSuspended(
            peerFix.wall,
            _peerFixWindow,
            'P2c (the backgrounded burst receive)',
          );
          expect(
            peerFix.fix,
            isNotNull,
            reason:
                'A peer published a kind-445 to this circle while this '
                'process was OS-backgrounded, a burst was driven through the '
                'production scheduler afterwards, and '
                '${_peerFixWindow.inSeconds}s later '
                "the app's member-location cache still holds nothing from "
                'that peer (${peerFix.polls} cache read(s); the tick '
                'returned after ${receiveTickWall.inSeconds}s). Read that tick '
                'figure first: '
                'at or near ${kPublishLinkTimeout.inSeconds}s the chain '
                'watchdog returned while the burst was still running, so the '
                'ingest may simply not have happened YET and the window '
                'below is not the bound to look at. Well below it, the burst '
                'finished and this is the RECEIVE half failing: the open '
                'issued no REQ, the backlog wait returned before the stored '
                'replay, or the decrypted event never reached the router. The '
                'peer event '
                'reached the relay before the tick was driven (its OK is '
                'awaited), so "it was not there yet" is not available as an '
                'explanation.',
          );
          // Presence is not decryption. A cache row can be written for a pubkey
          // whose payload never parsed, so the coordinates are what say the
          // kind-445 was peeled, decrypted and understood.
          expect(
            peerFix.fix!.latitude,
            closeTo(_peerLatitude, 1e-6),
            reason:
                'the cached entry for the peer carries coordinates that are '
                'not the ones it published — the row exists but the payload '
                'behind it is not the peer location this burst was supposed '
                'to ingest',
          );
          expect(peerFix.fix!.longitude, closeTo(_peerLongitude, 1e-6));

          // ...and the burst that did it left nothing standing.
          //
          // The verdict is the engine's FIRST answer, taken with that burst's
          // own teardown already awaited. It is not "was the count ever zero in
          // a window", and the difference is the whole assertion: a burst OPEN
          // manufactures a zero of its own, because `resume_burst` flushes
          // `unsubscribe_all` before `connect()`, `wait_for_connection` and
          // `register_and_subscribe`. That flush only runs when the pool view
          // is non-empty — i.e. only when the PREVIOUS pause left its REQs
          // standing — so a leaking run reads non-zero here, and then reads
          // zero for seconds while the next jittered tick's burst opens. One
          // such tick is expected inside a window this size, so "ever zero"
          // would go green on exactly the leak it exists to catch, and the
          // receive half above would pass too, off the leaked standing REQ.
          //
          // The window is therefore NOT a bound on the promise and does not
          // need to bound a burst: it is what a read that THROWS is given, and
          // a wrong ANSWER ends the poll immediately. Its two terms are the
          // phase's own unit of work — the links a burst owns (`burstBound`)
          // plus the teardown it still owes (`kOptOutBurstWait`, the engine's
          // settle cap plus its four bounded lifecycle ops) — kept as the sum
          // the lane's host wrapper prices this phase at. The maintenance fold
          // between them is unpriced, for the reason `burstBound`'s own doc
          // gives: a due fold publishes through the commit ladder and no honest
          // bound on a whole burst exists. That costs nothing here precisely
          // because the verdict does not wait for the count to change.
          final betweenBurstsWindow = oneCircleBurstBound + kOptOutBurstWait;
          var quieting = true;
          final quietFuture = _pollPoolSubscriptions(
            subscriptions,
            betweenBurstsWindow,
            wanted: (count) => count == 0,
            decideOnFirstAnswer: true,
          ).whenComplete(() => quieting = false);
          final quietHeartbeat = _heartbeatWhile(
            () => quieting,
            betweenBurstsWindow,
            'the engine to ANSWER its standing-subscription count (the answer '
            'itself is the verdict; only a read that throws waits)',
          );
          final quiet = await quietFuture;
          await quietHeartbeat;

          _failIfSuspended(
            quiet.wall,
            betweenBurstsWindow,
            'P2c (the between-bursts subscription count)',
          );
          // Two failures reach this assertion and they need opposite fixes: a
          // count that answered non-zero, and a count that could not be read at
          // all (no live session, or a poisoned lock — the FFI throws rather
          // than answering zero, precisely so this stays distinguishable).
          final quietDetail = quiet.last == null
              ? 'every read of the count FAILED across '
                    '${betweenBurstsWindow.inSeconds}s — there is no live '
                    'session to ask, or its lock is poisoned'
              : 'the engine answered ${magnitudeBucket(quiet.last!)} standing '
                    'subscription(s) on the first read taken after the burst';
          expect(
            quiet.matched,
            isTrue,
            reason:
                '$quietDetail (${magnitudeBucket(quiet.polls)} read(s)), so '
                'the background '
                'receive plane is subscribed BETWEEN publish ticks — which is '
                'a continuous "this pubkey is online" signal to every circle '
                'relay and the 55 s keepalive traffic that goes with it, i.e. '
                'the state this whole phase exists to remove. The burst that '
                'should have cleared it is the one awaited immediately above, '
                'and its pause is deliberately non-throwing, so a sweep that '
                'failed reaches the caller as nothing but a log line — which '
                'is why this reads the count rather than the pause. Two other '
                'readings exist and the tick wall separates them: the tick '
                'returned after ${receiveTickWall.inSeconds}s, so at or near '
                '${kPublishLinkTimeout.inSeconds}s the chain watchdog reported '
                'a burst that was still holding its own REQs, and well below '
                'it the burst had finished and this is a pause that dropped '
                'nothing. It cannot be a vacuous zero either: the same counter '
                'read ${magnitudeBucket(foregroundStanding ?? 0)} while the '
                'app was foregrounded.',
          );
          debugPrint(
            '[bg-publish] between bursts: the engine answered '
            '${magnitudeBucket(quiet.last ?? 0)} standing subscription(s) on '
            'read #${magnitudeBucket(quiet.polls)}, '
            '${quiet.wall.inSeconds}s after the burst.',
          );
          debugPrint(kBackgroundReceiveMarker);
        } else {
          // =================================================================
          // P2d — the POLL path's background CATCH-UP runs, from a process iOS
          // has genuinely backgrounded.
          //
          // The rollback configuration's background receive plane is not a
          // burst. It is `MapShell._startIosBackgroundReceiveTimer`'s
          // `Timer.periodic(90 s)`, installed on the iOS pause branch and
          // compiled out of every live-sync build (the method returns on
          // `liveSyncEnabled`); each tick calls `_runBackgroundCatchUp()`,
          // which is `CatchupService.runCatchup(isBackgroundWake: true)`.
          //
          // That timer is what this leg exists for, and nothing else in the
          // repo fires it under a real OS backgrounding: `e2e-ios` runs its
          // poll variant foregrounded, and check 6 of
          // `check_ios_background_publish.sh` stays green with the method
          // deleted outright (mutation-verified). OD4-d recorded that gap;
          // this phase is what closes it.
          //
          // The oracle is the sweep's OWN side effect in the PERSISTED
          // last-known store: Rust's `persist_locations` upserts one row per
          // decrypted location application message. On this leg nothing else
          // can write that row — the publish tick's burst open fails without
          // an engine (asserted in the foreground above, where the pool-count
          // read had to THROW), the foreground 30 s fetch timer was cancelled
          // at the pause, and no provider can recompute while frames are off.
          // So a row carrying the peer's sentinel coordinates is the timer,
          // its sweep and the MLS decrypt, all three at once.
          //
          // A FOURTH premise, and the fragile one, because it is not a fact
          // about Dart: `registerIosBackgroundCatchupHandler` (main.dart,
          // flag-independent) reaches the SAME `persist_locations` from the
          // same `runCatchup`, driven by two native wakes. `HavenSLCHandler`
          // arms nothing without `.authorizedAlways`, so this leg's
          // `when-in-use` grant excludes it — an (always, poll) leg would NOT
          // be attributable and must not be added on cost grounds alone.
          // `HavenBGTaskHandler` is not tier-gated at all; only the Simulator
          // excludes it (`BGTaskScheduler.submit` throws `notPermitted` there,
          // swallowed), which is the same simulator ceiling the lane header
          // states for jetsam and SLC relaunch. On a device this phase would
          // need a different oracle.
          //
          // What P2d does NOT prove: anything at all about the burst plane,
          // which this build does not have; and not the C3 chokepoint that
          // must refuse a wake once consent is withdrawn — the C4 watcher
          // cancels this timer on that edge before the chokepoint is reached,
          // and host tests own both halves
          // (`test/pages/map_shell_ios_receive_timer_test.dart`).
          // =================================================================
          //
          // The BASELINE first. The peer has published nothing all run, so
          // this can only fail on a store that was not empty — and without it
          // a row written at any earlier point would let the poll below pass
          // on something the backgrounded sweep never did.
          final storeBaseline = await _pollForStoredPeerFix(
            circleService,
            creation.circle.nostrGroupId,
            bob.pubkeyHex,
            _storeBaselineWindow,
          );
          expect(
            storeBaseline.fix,
            isNull,
            reason:
                'The persisted last-known store ALREADY holds a row for the '
                'peer, before he has published anything '
                '(${storeBaseline.polls} read(s) over '
                '${_storeBaselineWindow.inSeconds}s). P2d reads '
                "the appearance of that row as the sweep's work, so a row "
                'that predates the publish below would let this phase pass '
                'with the receive timer never having fired.',
          );

          final peerEventId = await bob.publishLocation(
            circle: bobCircle,
            latitude: _peerLatitude,
            longitude: _peerLongitude,
            relay: relay,
          );
          debugPrint(
            '[bg-publish] peer published a location while Alice was '
            'backgrounded (evt='
            '${logAliasHandle(LogAliasClass.event, peerEventId)}).',
          );

          // No tick is driven here, unlike P2c, and that IS the phase: the
          // subject is the timer. Driving anything would replace the
          // mechanism under test with this drive's own call.
          var sweeping = true;
          final catchupFuture = _pollForStoredPeerFix(
            circleService,
            creation.circle.nostrGroupId,
            bob.pubkeyHex,
            _pollPathCatchupWindow,
          ).whenComplete(() => sweeping = false);
          final catchupHeartbeat = _heartbeatWhile(
            () => sweeping,
            _pollPathCatchupWindow,
            "the poll path's "
                '${_pollPathReceiveInterval.inSeconds}s background receive '
                'timer to catch the peer up',
          );
          final catchup = await catchupFuture;
          await catchupHeartbeat;

          _failIfSuspended(
            catchup.wall,
            _pollPathCatchupWindow,
            'P2d (the poll-path background catch-up)',
          );
          expect(
            catchup.fix,
            isNotNull,
            reason:
                'A peer published a kind-445 to this circle while this '
                'process was OS-backgrounded, and '
                '${_pollPathCatchupWindow.inSeconds}s later the persisted '
                'last-known store still holds nothing from him '
                '(${magnitudeBucket(catchup.polls)} read(s)). That window '
                'spans TWO of the '
                '${_pollPathReceiveInterval.inSeconds}s receive-timer ticks '
                "plus the sweep's own deadline, so one missed tick is not an "
                'explanation. Check, in this order: that P2a/P2b above passed '
                '(a suspended process runs no timer at all), that '
                "`_onPaused`'s iOS branch still calls "
                '`_startIosBackgroundReceiveTimer` and that the method still '
                'arms a timer when `liveSyncEnabled` is false, and that '
                '`CatchupService.runCatchup(isBackgroundWake: true)` still '
                'passes its C3 consent gate (background sharing is ON here — '
                'P3 has not run yet). The peer event was ACKed by the relay '
                'before this window opened, so "it was not there yet" is not '
                'available either.',
          );
          // Presence is not decryption. A row can be written for a pubkey
          // whose payload never parsed, so the coordinates are what say the
          // kind-445 was peeled, decrypted and understood.
          expect(
            catchup.fix!.latitude,
            closeTo(_peerLatitude, 1e-6),
            reason:
                'the persisted row for the peer carries coordinates that are '
                'not the ones he published — the row exists but the payload '
                'behind it is not the peer location the sweep was supposed to '
                'ingest',
          );
          expect(catchup.fix!.longitude, closeTo(_peerLongitude, 1e-6));
          debugPrint(
            "[bg-publish] poll-path catch-up: the peer's location reached the "
            'persisted store on read #${magnitudeBucket(catchup.polls)}, '
            '${catchup.wall.inSeconds}s after his publish.',
          );
          debugPrint(kBackgroundCatchupMarker);
        }

        // The peer's last act is behind us, so his data directory can go —
        // and it MUST go before P3, which attributes every kind-445 created
        // after the disable cutoff to a scheduler that outlived consent.
        await bob.dispose();

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
            'since': backgroundedSecs,
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
            'since': backgroundedSecs,
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
            '[bg-publish] ${magnitudeBucket(straggled)} in-flight '
            'publish(es) created at or before the disable cutoff landed '
            'late — tolerated, not a leak.',
          );
        }
        expect(
          leaked.map((TestRelayEvent e) => e.id).toList(growable: false),
          isEmpty,
          reason:
              '${magnitudeBucket(leaked.length)} kind-445 event(s) for this '
              'circle were created MORE than ${_inFlightGraceSecs}s after '
              'background sharing was disabled (while still OS-backgrounded) '
              'and '
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
    // The INNERMOST of the lane's three bounds, and the only one that names
    // this test when it fires. It is PER LEG, because the two receive planes
    // do not cost the same and a single number would have to be the larger —
    // which on the cheaper leg is a bound that can no longer fire before the
    // retry deadline above it.
    //
    // LIVE-SYNC legs (40m). setup ~5m, P1 ~4m (60s stream freshness + 95s
    // standing-REQ control + <=60s of confirmed-Always poll on the Always
    // leg), the paused-transition poll 3m, P2a ~4m (its pause-burst wait plus
    // an awaited tick priced at `kPublishLinkTimeout`), P2b ~7m, P2c ~8m (the
    // peer's re-issuing publish, a second awaited tick at that same ceiling,
    // and the two engine polls), P3 ~5m, teardown ~2m ≈ 38m.
    //
    // POLL leg (37m). The same setup and P2a/P2b, but P1 loses both live-sync
    // terms (~1m: 60s of stream freshness, and a pool-count read that THROWS
    // at once instead of a 95s wait for a standing REQ), and P2d replaces P2c
    // at ~6m instead of ~8m — the peer's publish is the same 112s, then a
    // 215s catch-up window (two `_pollPathReceiveInterval` ticks + the sweep
    // deadline + slack) and NO awaited tick at all, because this phase drives
    // nothing. 5 + 1 + 3 + 4 + 7 + 6 + 5 + 2 ≈ 33m by that list, ~34.6m when
    // the same phases are summed in SECONDS rather than rounded minutes (the
    // wrapper's derivation prices the middle of it at 1241s and sets
    // DISABLE_WAIT_POLL_SECS to 1310 — never set that constant to 1241, which
    // is the sum it has to CLEAR), so 37 clears it by ~7%.
    //
    // The margin over each sum is thin — thinnest on the live-sync legs, whose
    // 40m sits ~5% over 38m — and it is deliberately not spent by raising
    // either: the `kPublishLinkTimeout` terms are WATCHDOG exits — a burst that
    // ran past 3 minutes — and against a localhost relay a healthy burst is
    // seconds, so a run that approaches the sum has already failed one of the
    // assertions those ticks feed. Raising a value here is also not a local
    // edit: each must stay far enough inside the matching per-attempt retry
    // deadline in e2e-ios-background-publish.yml, whose derivation reads these
    // values and whose pairing check 15 of check_ios_background_publish.sh
    // enforces branch by branch. Raise one and re-derive the other in the same
    // commit.
    timeout: const Timeout(Duration(minutes: liveSyncEnabled ? 40 : 37)),
  );
}
