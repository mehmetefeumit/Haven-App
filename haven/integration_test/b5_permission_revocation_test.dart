/// B5 drive target — the app's behaviour when the user REVOKES its location
/// permission (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B5).
///
/// Driven by `tooling/e2e/ci/run-b5-permission-revocation.sh`, which runs
/// this ONE file TWICE against the same install: once with the permission
/// held (ACT 1), and once after `pm revoke` (ACT 2). The act is chosen by
/// the app itself, from the only fact that distinguishes them — what
/// `LocationService.checkPermission()` reports — so a revoke that silently
/// failed cannot be mistaken for a revoke that worked.
///
/// ## Why TWO acts and not one continuous session (this differs from B6)
///
/// `run-b6-location-provider-toggle.sh` keeps ONE drive alive and toggles
/// the OS provider underneath it, because `cmd location
/// set-location-enabled` leaves the process alone. `pm revoke` does not:
/// AOSP's `PermissionManagerServiceImpl.revokeRuntimePermissionInternal`
/// calls back into `PackageManagerService.onPermissionRevoked`, which posts
/// `killUid(appId, userId, KILL_APP_REASON_PERMISSIONS_REVOKED)` — the app
/// process is TERMINATED as part of the revocation. So on Android the
/// mid-session half of this scenario is enforced by the OS, and the app's
/// OWN `denied` / `deniedForever` branches
/// (`geolocator_location_service.dart:471-473` and `:474-482`) are reached
/// only on the NEXT launch. A single-drive lane could therefore only ever
/// prove "a dead process publishes nothing", which is true of any app and
/// says nothing about this one.
///
/// ACT 1 is written so it does NOT assume the kill. If the process survives
/// the revoke (a different OEM policy, a future AOSP change), it observes
/// the permission change from the inside and measures how long publishing
/// continues — see the stale-cache note below, which is the single most
/// important thing this target can report. If the process is killed, ACT 1
/// simply stops mid-sequence and the shell records the kill from logcat.
///
/// ## The stale-fix cache (READ THIS BEFORE CHANGING THE WINDOWS)
///
/// This lane was written against a defect it found and which is now FIXED;
/// the windows below are still sized for the defect on purpose, so keep
/// reading before tightening them.
///
/// The defect: `GeolocatorLocationService.getCurrentLocation()` served the
/// cached `_lastStreamPosition` whenever the cached GPS FIX TIME was within
/// `kStreamPositionMaxAge` (168 s) BEFORE it consulted either
/// `isLocationServiceEnabled()` or `checkPermission()`, and nothing cleared
/// that cache when access was withdrawn (`clearCachedPosition` ran only on
/// logout and on background-sharing opt-out). Losing location access
/// therefore did NOT stop publishing for up to 168 s wherever the process
/// survived the loss.
///
/// The fix: both gates now run before ANY position is produced — the cache
/// read and the iOS-backgrounded last-known branch included — and the cache
/// is cleared eagerly the moment access loss is observed (a denial, a
/// disabled provider, or the position stream erroring or closing).
///
/// What that means here. `MIDSESSION_TAIL` should now be ~0 rather than up
/// to 168 s, so it has changed from a measurement into a REGRESSION SIGNAL:
/// a tail approaching 168 s again means the gate was reordered back below
/// the cache read. The windows are deliberately NOT tightened to match,
/// because they are upper bounds on an ABSENCE assertion — a generous bound
/// makes the absence stronger, not weaker, and tightening it would only buy
/// flakiness on a loaded CI emulator.
///
/// ## The app-op phase (ACT 1) — the only arrangement that can see the cache
///
/// `pm revoke` MASKS the hazard above: the cache is process-local and dies
/// with the kill, so a revoke can never observe it. `cmd appops set --uid
/// PKG android:fine_location deny` is the reachable variant. It withdraws
/// location access WITHOUT killing the process and WITHOUT changing
/// anything the permission gate reads — `checkPermission()` and
/// `getLocationAccuracy()` both go to `ContextCompat.checkSelfPermission`,
/// which does not consult the app-op — and AOSP then drops deliveries with
/// no guaranteed stream error or close. Until
/// `GeolocatorLocationService._platformStillPermitsLocation` was added,
/// that state kept publishing the user's last position for the rest of the
/// 168 s window. So ACT 1 runs it, before the revoke, against a live
/// session, and asserts the promise itself: no coordinate produced, none
/// published.
///
/// `--uid` is not optional. `AppOpsService` resolves a non-default UID mode
/// and returns it without ever reading the package mode, and a `whileInUse`
/// grant leaves the UID mode at `foreground` — allowed for a foregrounded
/// app. The package-scoped form this lane shipped with therefore withdrew
/// nothing while `cmd appops get` still printed `deny` on the package line
/// (CI run 31868809387), and the shell now gates on the EFFECTIVE mode.
///
/// Two things stop it passing vacuously, and neither is optional:
///
/// * the shell reads the app-op back with `cmd appops get` and fails loudly
///   if it did not change — a `set` that silently no-ops satisfies every
///   assertion here;
/// * the app reports `streamAgeMs`, the age of the newest fix its position
///   stream delivered, both when it arms and at the decisive read. A run
///   whose cache had already gone stale on its own had nothing to leak, and
///   that is a FINDING rather than a pass. It needs the emulator GPS to
///   MOVE: re-issuing `adb emu geo fix` at one point is filtered out by the
///   stream's 1 m distance filter, and the cache then ages out by itself.
///
/// ## What ACT 2 proves that no unit test can
///
/// `haven/test/services/geolocator_location_service_test.dart` reaches the
/// `denied` / `deniedForever` branches only through a mocked
/// `GeolocatorWrapper`; every E2E scenario injects `FakeLocationService`,
/// whose `checkPermission()` is a hardcoded `LocationPermissionStatus
/// .always` (`e2e/_lib/fake_location_service.dart:57`). So the real
/// platform-channel refusal — the one a user actually gets — executed
/// nowhere in CI. ACT 2 runs it for real: a REAL `GeolocatorLocationService`
/// (no `locationServiceProvider` override), a REAL revoked permission, a
/// REAL publish-eligible circle, and a bounded window in which the app must
/// publish NOTHING.
///
/// ## Markers
///
/// Owned by this file. The shell matches them as fixed literals — change
/// here AND in `run-b5-permission-revocation.sh` together, or the lane
/// silently stops finding them.
library;

import 'dart:async' show TimeoutException;
import 'dart:io' show Platform, pid;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart'
    show kLocationPublishMaxInterval, kStreamPositionMaxAge;
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/location_provider.dart'
    show locationStreamProvider;
import 'package:haven/src/providers/location_publish_scheduler_provider.dart'
    show filterPublishEligibleCircles;
import 'package:haven/src/providers/location_sharing_provider.dart'
    show locationPublisherProvider;
import 'package:haven/src/providers/onboarding_provider.dart'
    show
        OnboardingController,
        OnboardingFlags,
        kOnboardingCompletedKey,
        kOnboardingIntroSeenKey,
        onboardingControllerProvider;
import 'package:haven/src/providers/service_providers.dart'
    show circleServiceProvider, locationServiceProvider;
import 'package:haven/src/rust/api.dart' show MemberKeyPackageFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/location_service.dart'
    show LocationPermissionStatus, LocationServiceException, Position;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound, waitUntilAsync;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;
import 'e2e/_lib/throw_time_error_capture.dart';

/// Printed once, first, with the act this process selected, the permission
/// status that selected it, and the OS pid.
///
/// The pid is load-bearing: the shell asserts ACT 2 ran in a DIFFERENT
/// process from ACT 1, which is what makes "the app was relaunched with the
/// permission revoked" a claim rather than an assumption.
const String kPhaseMarker = '[b5] PHASE';

/// ACT 1, with `n=<count>`: a production publish cycle reached `n` circles
/// while the permission was still held. PARSED by the shell, never grepped —
/// `n=0` is the failing case and contains the marker substring.
const String kBaselinePublishedMarker = '[b5] BASELINE_PUBLISHED';

/// ACT 1: the shell's cue to deny the location APP-OP, carrying the two
/// facts that keep the window after it from passing vacuously —
/// `streamAgeMs=<ms>` (how old the newest stream fix is, i.e. how warm the
/// cache being withheld actually is) and `eligible=<n>` (how many circles a
/// still-working publisher would reach). Both PARSED.
const String kAppOpsArmedMarker = '[b5] APPOPS_ARMED';

/// ACT 1, with `after=<seconds>`: the app observed, from inside a LIVE
/// session, that the platform had stopped serving location.
///
/// Its absence IS a defect here, unlike [kRevokeObservedMarker]: an app-op
/// denial does not kill the process, so an app that never notices is an app
/// the denial never reached.
const String kAppOpsObservedMarker = '[b5] APPOPS_OBSERVED';

/// ACT 1: location reads went on working for the whole observation window.
/// The app-op `set` did not take, or took and Android ignored it.
const String kAppOpsNotObservedMarker = '[b5] APPOPS_NOT_OBSERVED';

/// ACT 1, with `type=<runtimeType> streamAgeMs=<ms>`: the production
/// publish-path read refused while location access was withdrawn from the
/// running process. `streamAgeMs` is PARSED and must be below
/// `kStreamPositionMaxAge`, or the refusal proves nothing — a cache that had
/// already aged out would have been refused anyway.
const String kAppOpsGpsRefusedMarker = '[b5] APPOPS_GPS_REFUSED';

/// ACT 1: `getCurrentLocation()` RETURNED a coordinate after access was
/// withdrawn from the live process. The headline failure of this phase, and
/// the one `pm revoke` structurally cannot reach.
const String kAppOpsGpsLeakedMarker = '[b5] APPOPS_GPS_LEAKED';

/// ACT 1, per-cycle inside the app-op window: `i=<index> n=<published>`.
const String kAppOpsCycleMarker = '[b5] APPOPS_CYCLE';

/// ACT 1, with `cycles=<count> max=<highest-n> wedged=<count>`: the app-op
/// window closed. `max` is PARSED and must be 0; so is `wedged`.
const String kAppOpsDoneMarker = '[b5] APPOPS_DONE';

/// ACT 1: the shell's cue to run `pm revoke`. Everything after it is the
/// mid-session half of the scenario.
const String kAwaitingRevokeMarker = '[b5] AWAITING_REVOKE';

/// ACT 1: the app ITSELF observed the permission was gone. Only reachable
/// when the process SURVIVES the revoke; its absence is not a defect (see
/// the class doc) and the shell reads it as such.
const String kRevokeObservedMarker = '[b5] REVOKE_OBSERVED';

/// ACT 1, per-cycle evidence while the process survives a revoke:
/// `i=<index> t=<seconds-since-revoke> n=<published>`.
const String kMidSessionCycleMarker = '[b5] MIDSESSION_CYCLE';

/// ACT 1, with `tail=<seconds>`: how long publishing continued after the
/// permission was observed gone. Now that the access gate runs before any
/// position is produced this should be ~0; anything approaching
/// `kStreamPositionMaxAge` means the stale-fix cache described in the class
/// doc has been reintroduced.
const String kMidSessionTailMarker = '[b5] MIDSESSION_TAIL';

/// ACT 1: publishing NEVER stopped inside the bounded window — the app kept
/// broadcasting location after the user revoked its permission.
const String kMidSessionNeverStoppedMarker = '[b5] MIDSESSION_NEVER_STOPPED';

/// ACT 1: the process outlived the revoke, so the mid-session readings above
/// are real measurements rather than a truncated capture.
const String kSurvivedRevokeMarker = '[b5] SURVIVED_REVOKE';

/// ACT 2, with `eligible=<count>`: identity, disclosure and a
/// publish-eligible circle are all in place, so a still-publishing app WOULD
/// publish in the window that follows. The anti-vacuity check.
const String kAct2ArmedMarker = '[b5] ACT2_ARMED';

/// ACT 2, with `type=<runtimeType>`: a REAL one-shot location read was
/// refused. This is the `denied` / `deniedForever` branch executing.
const String kAct2GpsRefusedMarker = '[b5] ACT2_GPS_REFUSED';

/// ACT 2: a one-shot location read RETURNED A POSITION with the permission
/// revoked. The headline failure this act exists to catch.
const String kAct2GpsLeakedMarker = '[b5] ACT2_GPS_LEAKED';

/// ACT 2, per-cycle: `i=<index> n=<published>`.
const String kAct2CycleMarker = '[b5] ACT2_CYCLE';

/// A publish cycle that never returned, with `i=<index> after=<seconds>s`.
///
/// Distinct from `ACT2_CYCLE i=<i> n=0`, and the distinction is the point: a
/// cycle that published to zero circles is this lane PASSING, and a cycle that
/// wedged is a publish path that answered nothing at all. Collapsing the two
/// would let a hung publisher read as proof that the app stopped publishing.
///
/// Emitted by BOTH absence windows (the app-op one in ACT 1 and ACT 2's) —
/// the literal is deliberately not per-window, because attribution comes
/// from the `wedged=` field each window reports on its own `*_DONE` line.
const String kAct2WedgedMarker = '[b5] ACT2_WEDGED';

/// ACT 2, with `cycles=<count> max=<highest-n> wedged=<count>`: the window
/// closed. `max` is PARSED and must be 0; so is `wedged`.
const String kAct2DoneMarker = '[b5] ACT2_DONE';

/// Closes the capture in BOTH acts. Printed unconditionally, before the
/// terminal assertion, so the shell's oracle always reads a complete window.
const String kSequenceCompleteMarker = '[b5] SEQUENCE_COMPLETE';

/// How fresh the newest stream fix must be before ACT 1 arms the app-op
/// phase.
///
/// The cache is what the phase is about, so it has to be warm when access is
/// withdrawn. This bounds its age at ARMING; [kAppOpsGpsRefusedMarker]
/// carries the age at the decisive read, which is the one that has to be
/// inside `kStreamPositionMaxAge`.
const Duration _maxArmingStreamAge = Duration(seconds: 60);

/// How long ACT 1 waits for a fix fresh enough to arm the app-op phase.
const Duration _appOpsArmTimeout = Duration(seconds: 60);

/// How long ACT 1 waits for the app-op denial to become visible to the app.
const Duration _appOpsObservationTimeout = Duration(seconds: 150);

/// Consecutive refused one-shot reads before ACT 1 calls the app-op denial
/// observed.
///
/// One refusal could be a transient emulator GPS miss, and treating that as
/// the denial would open the absence window while access was still granted —
/// a false RED, since the app would legitimately publish. Confirmation is
/// only counted after a read has demonstrably WORKED inside the same loop,
/// so a path that was broken before the denial cannot satisfy it either.
const int _appOpsRefusalConfirmations = 2;

/// ACT 1's app-op absence window.
///
/// Deliberately shorter than [kStreamPositionMaxAge], unlike every other
/// window in this file, because it is not the discriminator: the one-shot
/// probe above is, and it runs while the cache is still WARM, where a
/// regression fails on its FIRST call rather than after 168 s. What this
/// window adds is repetition — several production publish cycles, all
/// reaching zero circles. The claim that needs a full scheduler interval
/// behind it (nothing publishes in the background either) is the relay-side
/// one, and the shell holds the app-op denied for at least
/// [kLocationPublishMaxInterval] to cover it.
const Duration _appOpsAbsenceWindow = Duration(seconds: 90);

/// Spacing between ACT 1's app-op publish attempts.
const Duration _appOpsCycleSpacing = Duration(seconds: 15);

/// How long ACT 1 waits for the shell's `pm revoke` to become visible to the
/// app. Only ever consumed when the process survives the revoke; when the OS
/// kills it (the normal Android outcome) this wait never returns.
const Duration _revokeObservationTimeout = Duration(seconds: 120);

/// ACT 1's mid-session observation window, opened when the app observes the
/// permission is gone.
///
/// Must exceed [kStreamPositionMaxAge] (168 s). That bound is kept from
/// before the access gate was fixed, when a cached fix newer than it meant
/// `getCurrentLocation()` never reached the permission check at all and
/// publishing continued on the last fix. Publishing should now stop
/// promptly, but the window stays wide deliberately: it bounds an ABSENCE,
/// so a generous bound makes the assertion stronger, and it is the only
/// thing that would still catch a regression reinstating the stale read.
/// 90 s of slack covers a loaded CI emulator and the poll granularity.
final Duration _midSessionWindow =
    kStreamPositionMaxAge + const Duration(seconds: 90);

/// Spacing between ACT 1's mid-session publish attempts.
const Duration _midSessionCycleSpacing = Duration(seconds: 12);

/// Consecutive zero-publish confirmations before ACT 1 calls publishing
/// stopped. One reading could be a transient GPS miss; four spaced readings
/// distinguish "stopped" from "flaky".
const int _sustainedZeroChecks = 4;

/// ACT 2's absence window.
///
/// Sized from [kLocationPublishMaxInterval] (168 s), the longest interval
/// the per-circle scheduler can sample, so a still-publishing app must have
/// fired at least one scheduled publish inside it — on top of the cold-start
/// burst `locationPublisherProvider` runs on first fix. 90 s of slack covers
/// a loaded CI emulator. It also exceeds [kStreamPositionMaxAge], so a
/// stale-fix tail could not hide inside the window either.
final Duration _act2AbsenceWindow =
    kLocationPublishMaxInterval + const Duration(seconds: 90);

/// Spacing between ACT 2's publish attempts inside [_act2AbsenceWindow].
const Duration _act2CycleSpacing = Duration(seconds: 30);

/// Bound on the ACT 2 one-shot location probe.
///
/// A revoked-but-not-`USER_FIXED` permission makes geolocator's
/// `requestPermission()` raise the SYSTEM permission dialog, which nothing
/// in CI will dismiss, so an unbounded probe would hang to the drive
/// timeout with no attribution. The shell sets `pm set-permission-flags
/// user-fixed` precisely to avoid that; this bound is what turns a failure
/// of that step into a named finding instead of a hang.
const Duration _gpsProbeTimeout = Duration(seconds: 75);

/// Bound on ONE publish cycle.
///
/// The same hazard [_gpsProbeTimeout] guards, one step further along the same
/// path — and for a long time the only one of the two that was guarded.
/// `publishNow` awaits the real publish provider, which reaches the platform
/// location plugin, so it is exactly as able to never return as the one-shot
/// probe is. Neither of its callers supplies a bound: [waitUntilAsync] re-reads
/// its own deadline only BETWEEN polls, so a poll that never returns outlives
/// it, and ACT 2's absence loop awaited it bare.
///
/// That cost the whole lane in CI run 30925179141. ACT 2's one-shot probe
/// reported its own `TimeoutException` correctly, the absence loop then called
/// the same path unbounded on its FIRST cycle, and the drive died at the
/// 13-minute per-test timeout having printed no [kAct2DoneMarker] — so the
/// app-side half of the proof was simply absent and the shell could report
/// only its absence, not what happened.
///
/// Sized so a whole window still fits: 45 s + [_act2CycleSpacing] is 75 s
/// worst case per cycle, and [_act2AbsenceWindow] is 258 s, so even an
/// all-wedged window closes and prints its marker.
const Duration _publishCycleTimeout = Duration(seconds: 45);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B5: revoking location permission mid-session stops the app publishing, '
    'and it stays stopped across the relaunch the revoke forces',
    (tester) async {
      installThrowTimeErrorLogging();
      // `pm revoke` and the runtime-permission model under test are Android's.
      // iOS authorization tiers are backlog B7 (`b7_ios_auth_tier_test.dart`).
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b5_permission_revocation_test drives the Android `pm revoke` '
          'runtime-permission model; skipped on non-Android runtimes.',
        );
        return;
      }

      // Verdicts collected across the sequence and asserted ONCE at the end,
      // so a failure never strands the shell mid-revoke and every marker the
      // oracle reads has already reached logcat.
      final failures = <String>[];

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice under the PRODUCTION secure-storage key, with onboarding and
      // both location disclosures pre-accepted (the publisher self-skips
      // until the foreground disclosure flag is set).
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;
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
      // pumpUntilFound, never pumpAndSettle: MapShell's periodic timers keep
      // the frame queue non-empty forever.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      // The app's OWN container — never a drive-owned second one, or the
      // providers read here would not be the ones the UI is running on.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      await container.read(identityProvider.future);
      expect(
        container.read(identityProvider).valueOrNull,
        isNotNull,
        reason: 'identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding — nothing downstream can '
            'publish, in either act.',
      );

      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b5] circleServiceProvider is not Nostr-backed in this run — the '
          'production publish path this target exercises was bypassed.',
        );
      }
      final manager = await circleService.getCircleManagerFfi();

      // NO `locationServiceProvider` override: the whole point is the REAL
      // GeolocatorLocationService and the REAL platform permission gate.
      final locationService = container.read(locationServiceProvider);

      // --- Act selection. The permission IS the discriminator, so a revoke
      // that silently did not take cannot be mistaken for one that did: the
      // process would simply run ACT 1 again, publish, and the shell's
      // relay-side window would go red with a real finding rather than a
      // green run that proved nothing.
      final permission = await locationService.checkPermission();
      final isAct1 = permission == LocationPermissionStatus.whileInUse ||
          permission == LocationPermissionStatus.always;
      debugPrint(
        '$kPhaseMarker act=${isAct1 ? 1 : 2} perm=${permission.name} pid=$pid',
      );

      // A creator-only circle is enough, and is deliberately simpler than
      // B1's two-user setup: `filterPublishEligibleCircles` and
      // `locationPublisherProvider` both key on `MembershipStatus.accepted`,
      // which `create_circle` stamps on the creator's own row
      // (haven-core/src/circle/manager.rs). `publishLocation` resolves only
      // once a relay OK-acked (Security Rule 13), so the baseline is a
      // DELIVERY claim without needing a second party.
      await withFreshSecret(
        () =>
            container.read(identityNotifierProvider.notifier).getSecretBytes(),
        (aliceSecret) => createCircleConfirmed(
          manager: manager,
          relay: relay,
          identitySecretBytes: aliceSecret,
          members: const <MemberKeyPackageFfi>[],
          name: 'B5 Permission Revocation Circle',
          circleType: 'location_sharing',
          relays: <String>[defaultStrfryUrl],
          creatorFallbackRelays: <String>[defaultStrfryUrl],
          label: 'b5',
        ),
      );

      /// Cycles that exceeded [_publishCycleTimeout]. Read by ACT 2.
      var wedgedCycles = 0;

      /// Runs one production publish cycle and returns the number of circles
      /// it published to, or `null` if the cycle never answered.
      ///
      /// `locationPublisherProvider` swallows every publish FAILURE into `0`,
      /// which is exactly the signal both acts need — but it cannot swallow a
      /// call that does not return, so the bound has to live here (see
      /// [_publishCycleTimeout]).
      ///
      /// `null` rather than `0`: a wedged cycle is not evidence the app
      /// published nothing, and returning `0` would let a hung publisher read
      /// as this lane's PASSING condition. The timeout is deliberately not
      /// rethrown — every caller has to stay able to finish its window and
      /// print its terminal marker, because the shell's oracle reads markers,
      /// not exceptions.
      Future<int?> publishNow() async {
        container.invalidate(locationPublisherProvider);
        try {
          return await container
              .read(locationPublisherProvider.future)
              .timeout(_publishCycleTimeout);
        } on TimeoutException {
          wedgedCycles += 1;
          debugPrint(
            '$kAct2WedgedMarker i=$wedgedCycles '
            'after=${_publishCycleTimeout.inSeconds}s',
          );
          return null;
        }
      }

      /// How many circles a still-working publisher would publish to.
      Future<int> eligibleCircleCount() async {
        final circles = await circleService.getVisibleCircles();
        return filterPublishEligibleCircles(circles, circleService).length;
      }

      // Release the probe socket before either act's observation window: any
      // traffic it generated inside the window the shell scopes its
      // relay-side absence proof to would be indistinguishable from the
      // app's own publishes.
      Future<void> releaseProbe() async {
        try {
          await relay.dispose();
        } on Object catch (_) {
          // Best-effort; affects neither act's proof.
        }
      }

      /// The age of the newest fix the app's own position stream delivered.
      ///
      /// `getLocationStream()` tees every emission into the service's cache
      /// and judges that cache by the same GPS fix time, so this bounds the
      /// cache's age from ABOVE — measurable from outside the service, which
      /// has no accessor for it and must not grow one for a test.
      ///
      /// An upper bound, not the age itself, and the gap is real: every
      /// `_noteAccessLost` path CLEARS the cache while this provider keeps
      /// its last value. Run 31868809387 caught exactly that — an app-op mode
      /// edit re-evaluated the live registration, geolocator surfaced it as a
      /// stream error, the service dropped the fix, and this still reported a
      /// 129 s-old one. So a fresh reading proves the cache was not merely
      /// STALE; it does not prove the cache was still populated, and the
      /// refusal below is a claim about the promise ("no coordinate is
      /// produced"), never about which door inside the service refused.
      Duration? newestStreamFixAge() {
        final position = container.read(locationStreamProvider).valueOrNull;
        if (position == null) return null;
        return DateTime.now().difference(position.timestamp);
      }

      if (isAct1) {
        // ===================================================================
        // ACT 1 — the permission is held. Publish, then hand the shell two
        // cues in turn: deny the APP-OP (access withdrawn, process alive —
        // the only arrangement in which the stale-fix cache is observable),
        // and then `pm revoke` (which ends the process).
        // ===================================================================
        var baseline = 0;
        try {
          await waitUntilAsync(
            () async {
              baseline = await publishNow() ?? 0;
              return baseline >= 1;
            },
            description: 'a publish cycle reached >= 1 circle with '
                'ACCESS_FINE_LOCATION granted (needs an emulator GPS fix — '
                'the shell seeds one with `adb emu geo fix`)',
            timeout: const Duration(seconds: 150),
            pollInterval: const Duration(seconds: 6),
          );
        } on Object catch (e) {
          failures.add(
            'baseline publish never succeeded (${e.runtimeType}) — with the '
            'permission GRANTED the app must publish, or nothing this lane '
            'observes after the revoke can be attributed to it',
          );
        }
        debugPrint('$kBaselinePublishedMarker n=$baseline');

        await releaseProbe();

        // -------------------------------------------------------------------
        // THE APP-OP HALF — location access withdrawn from a LIVE process.
        // See the class doc; this is the only arrangement that can observe
        // the stale-fix cache, and `pm revoke` structurally cannot.
        // -------------------------------------------------------------------
        var armingStreamAgeMs = -1;
        try {
          await waitUntilAsync(
            () async {
              final age = newestStreamFixAge();
              if (age == null || age > _maxArmingStreamAge) return false;
              armingStreamAgeMs = age.inMilliseconds;
              return true;
            },
            description: 'the position stream delivered a fix newer than '
                '${_maxArmingStreamAge.inSeconds}s, so the cache the app-op '
                'window is about is warm and has something to leak',
            timeout: _appOpsArmTimeout,
            pollInterval: const Duration(seconds: 3),
          );
        } on Object catch (e) {
          failures.add(
            'no stream fix newer than ${_maxArmingStreamAge.inSeconds}s '
            'before the app-op window (${e.runtimeType}). The cache had '
            'already aged out, so refusing to serve it proves nothing. The '
            'emulator GPS has to MOVE: `adb emu geo fix` re-issued at one '
            "point is filtered out by the stream's 1 m distance filter.",
          );
        }

        final appOpsEligible = await eligibleCircleCount();
        if (appOpsEligible < 1) {
          failures.add(
            'no publish-eligible circle exists for the app-op window, so '
            '"the app published nothing" is vacuous there — it had nowhere '
            'to publish regardless of the app-op',
          );
        }

        // The shell denies the app-op when it sees this.
        debugPrint(
          '$kAppOpsArmedMarker streamAgeMs=$armingStreamAgeMs '
          'eligible=$appOpsEligible',
        );

        /// One REAL one-shot read, bounded, reported as worked / did not.
        ///
        /// `getCurrentLocationFresh()` never consults the cache, so polling
        /// it cannot itself produce the outcome the window below asserts —
        /// which is the whole reason the app watches this rather than the
        /// publish path.
        Future<bool> freshReadWorks() async {
          try {
            await locationService
                .getCurrentLocationFresh()
                .timeout(_gpsProbeTimeout);
            return true;
          } on Object catch (_) {
            return false;
          }
        }

        // The app cannot READ the app-op — that is the entire premise — so
        // it waits for the one consequence it can see.
        final armedAt = DateTime.now();
        var sawWorkingRead = false;
        var consecutiveRefusals = 0;
        var appOpsObserved = false;
        try {
          await waitUntilAsync(
            () async {
              if (await freshReadWorks()) {
                sawWorkingRead = true;
                consecutiveRefusals = 0;
                return false;
              }
              consecutiveRefusals += 1;
              return sawWorkingRead &&
                  consecutiveRefusals >= _appOpsRefusalConfirmations;
            },
            description: 'real one-shot location reads stopped working after '
                'the shell denied the location app-op',
            timeout: _appOpsObservationTimeout,
            pollInterval: const Duration(seconds: 3),
          );
          appOpsObserved = true;
        } on Object catch (_) {
          // Reported below. This is the discrimination gate, not an error.
        }
        if (appOpsObserved) {
          debugPrint(
            '$kAppOpsObservedMarker '
            'after=${DateTime.now().difference(armedAt).inSeconds}',
          );
        } else {
          debugPrint(kAppOpsNotObservedMarker);
          failures.add(
            'location reads still worked '
            '${_appOpsObservationTimeout.inSeconds}s after the shell denied '
            'the location app-op, so nothing below is an observation of an '
            'app that lost access. The shell read-back separates the two '
            'causes: an app-op that did not change at all, or one that '
            'changed and had no effect',
          );
        }

        // --- THE PROMISE, stated directly. With access withdrawn from a
        // live process, the production publish-path read must produce
        // NOTHING. It runs here, first, while the cache is still warm: a
        // build without the corroboration in
        // `GeolocatorLocationService._platformStillPermitsLocation` returns
        // the cached coordinate on this very call.
        final ageAtProbe = newestStreamFixAge();
        final ageAtProbeMs = ageAtProbe?.inMilliseconds ?? -1;
        Position? appOpsLeaked;
        Object? appOpsRefusal;
        try {
          appOpsLeaked = await locationService
              .getCurrentLocation()
              .timeout(_gpsProbeTimeout);
        } on Object catch (e) {
          appOpsRefusal = e;
        }
        if (appOpsLeaked != null) {
          debugPrint('$kAppOpsGpsLeakedMarker streamAgeMs=$ageAtProbeMs');
          failures.add(
            'getCurrentLocation() RETURNED A POSITION after location access '
            'was withdrawn from the running process. The permission gate '
            'cannot see an app-op, so this is the cached fix being served '
            'past the consent that produced it',
          );
        } else {
          // Type only, never the message (Security Rule 8).
          debugPrint(
            '$kAppOpsGpsRefusedMarker type=${appOpsRefusal.runtimeType} '
            'streamAgeMs=$ageAtProbeMs',
          );
          if (ageAtProbe == null || ageAtProbe > kStreamPositionMaxAge) {
            failures.add(
              'the app-op probe refused, but the newest stream fix was '
              '${ageAtProbeMs}ms old — outside kStreamPositionMaxAge '
              '(${kStreamPositionMaxAge.inMilliseconds}ms), so the cache '
              'would have been refused with the app-op untouched and this '
              'refusal discriminates nothing',
            );
          }
        }

        // --- Repetition: production publish cycles, all reaching zero. The
        // relay-side proof the shell runs covers the per-circle scheduler
        // ticking in the background, which these explicit calls cannot see.
        final appOpsDeadline = DateTime.now().add(_appOpsAbsenceWindow);
        var appOpsCycles = 0;
        var appOpsMax = 0;
        final appOpsWedgedBefore = wedgedCycles;
        while (DateTime.now().isBefore(appOpsDeadline)) {
          final n = await publishNow();
          appOpsCycles += 1;
          if (n != null && n > appOpsMax) {
            appOpsMax = n;
          }
          debugPrint('$kAppOpsCycleMarker i=$appOpsCycles n=${n ?? -1}');
          await Future<void>.delayed(_appOpsCycleSpacing);
        }
        final appOpsWedged = wedgedCycles - appOpsWedgedBefore;
        debugPrint(
          '$kAppOpsDoneMarker cycles=$appOpsCycles max=$appOpsMax '
          'wedged=$appOpsWedged',
        );
        if (appOpsCycles < 1) {
          failures.add(
            'the app-op absence window ran zero publish cycles — it proved '
            'nothing about what the app does once access is withdrawn',
          );
        }
        if (appOpsWedged > 0) {
          failures.add(
            '$appOpsWedged of $appOpsCycles app-op publish cycle(s) never '
            'returned within ${_publishCycleTimeout.inSeconds}s. A publish '
            'path that hangs is not one that declined to publish, and this '
            'lane may not report the second when it observed the first',
          );
        }
        if (appOpsMax > 0) {
          failures.add(
            'the app published location to $appOpsMax circle(s) after the '
            'location app-op was denied — access was withdrawn and the app '
            'went on broadcasting the position it already held',
          );
        }

        // The shell restores the app-op when it sees the window close, and
        // revokes the PERMISSION when it sees this. On stock Android the
        // process does not survive the next few lines — see the class doc.
        debugPrint(kAwaitingRevokeMarker);

        var observedRevoked = false;
        try {
          await waitUntilAsync(
            () async {
              final now = await locationService.checkPermission();
              return now == LocationPermissionStatus.denied ||
                  now == LocationPermissionStatus.deniedForever;
            },
            description: 'the app observed its own location permission as '
                'revoked after the shell ran `pm revoke`',
            timeout: _revokeObservationTimeout,
            pollInterval: const Duration(seconds: 3),
          );
          observedRevoked = true;
        } on Object catch (_) {
          // NOT a failure. The expected Android outcome is that this process
          // was killed by `killUid(... KILL_APP_REASON_PERMISSIONS_REVOKED)`
          // long before the wait could return; the shell records the kill
          // from logcat and ACT 2 carries the proof from there.
        }

        if (observedRevoked) {
          final after = await locationService.checkPermission();
          debugPrint('$kRevokeObservedMarker perm=${after.name}');

          // The process outlived the revoke, so the app's OWN behaviour
          // mid-session is observable. Measure how long publishing continues.
          // Before the access gate was fixed this ran to the full 168 s of
          // the stale-fix cache; it should now be ~0, and a long tail is the
          // signature of that regression returning.
          final revokedAt = DateTime.now();
          final deadline = revokedAt.add(_midSessionWindow);
          var consecutiveZeros = 0;
          var index = 0;
          int? tailSeconds;
          while (DateTime.now().isBefore(deadline)) {
            final n = await publishNow();
            final elapsed = DateTime.now().difference(revokedAt).inSeconds;
            index += 1;
            debugPrint('$kMidSessionCycleMarker i=$index t=$elapsed n=$n');
            if (n == 0) {
              consecutiveZeros += 1;
              if (consecutiveZeros >= _sustainedZeroChecks) {
                tailSeconds = elapsed;
                break;
              }
            } else {
              consecutiveZeros = 0;
            }
            await Future<void>.delayed(_midSessionCycleSpacing);
          }

          if (tailSeconds == null) {
            debugPrint(kMidSessionNeverStoppedMarker);
            failures.add(
              'publishing never stopped in the '
              '${_midSessionWindow.inSeconds}s after the permission was '
              'revoked — the app kept broadcasting location with no '
              'permission to collect it',
            );
          } else {
            debugPrint('$kMidSessionTailMarker tail=$tailSeconds');
          }
          debugPrint(kSurvivedRevokeMarker);
        }
      } else {
        // ===================================================================
        // ACT 2 — relaunched with the permission revoked. This is where the
        // production `denied` / `deniedForever` branches actually execute.
        // ===================================================================
        if (permission == LocationPermissionStatus.notDetermined) {
          failures.add(
            'checkPermission() reported notDetermined — the app has never '
            'asked, which is not the post-revocation state this act exists '
            'to test. Suspect `pm clear` without the re-revoke, or a '
            'reinstall between acts.',
          );
        }

        final eligible = await eligibleCircleCount();
        debugPrint('$kAct2ArmedMarker eligible=$eligible');
        if (eligible < 1) {
          failures.add(
            'no publish-eligible circle exists in ACT 2, so "the app '
            'published nothing" is vacuous — it had nowhere to publish to '
            'regardless of the permission',
          );
        }

        await releaseProbe();

        // --- The branch under test, executed for real. A revoked permission
        // must make a one-shot read FAIL, not fall back to anything.
        Position? leaked;
        Object? refusal;
        try {
          leaked = await locationService
              .getCurrentLocation()
              .timeout(_gpsProbeTimeout);
        } on Object catch (e) {
          refusal = e;
        }
        if (leaked != null) {
          debugPrint(kAct2GpsLeakedMarker);
          failures.add(
            'getCurrentLocation() RETURNED A POSITION with the location '
            'permission revoked — the app can still read the device '
            'position after the user took that away',
          );
        } else {
          // Type only, never the message (Security Rule 8).
          debugPrint('$kAct2GpsRefusedMarker type=${refusal.runtimeType}');
          if (refusal is TimeoutException) {
            failures.add(
              'getCurrentLocation() did not return within '
              '${_gpsProbeTimeout.inSeconds}s. Two causes, and the shell '
              'read-back separates them: if `pm set-permission-flags ... '
              'user-fixed` did NOT take, the gate raised a real system '
              'dialog nobody answers. If it did take, the prompt was '
              'answered instantly and something CANCELLED this call — the '
              'shape to look for is a second permission request racing this '
              'one (logcat: "Can request only one set of permissions at a '
              'time"), which strands whichever caller asked first',
            );
          } else if (refusal is! LocationServiceException) {
            failures.add(
              'getCurrentLocation() failed with ${refusal.runtimeType} '
              'rather than LocationServiceException — the service layer did '
              'not take its own denied/deniedForever branch, so the refusal '
              'came from somewhere this lane cannot attribute',
            );
          }
        }

        // --- The absence window. Every cycle must publish to ZERO circles,
        // and the shell independently proves the same thing off the relay
        // (which also covers the per-circle scheduler ticking in the
        // background, invisible to the calls below).
        final deadline = DateTime.now().add(_act2AbsenceWindow);
        var cycles = 0;
        var maxPublished = 0;
        final wedgedBefore = wedgedCycles;
        while (DateTime.now().isBefore(deadline)) {
          final n = await publishNow();
          cycles += 1;
          if (n != null && n > maxPublished) {
            maxPublished = n;
          }
          // `n=-1` for a wedged cycle: the marker's field stays numeric for
          // the shell's parser, and -1 cannot collide with a real count.
          debugPrint('$kAct2CycleMarker i=$cycles n=${n ?? -1}');
          await Future<void>.delayed(_act2CycleSpacing);
        }
        final wedgedHere = wedgedCycles - wedgedBefore;
        debugPrint(
          '$kAct2DoneMarker cycles=$cycles max=$maxPublished '
          'wedged=$wedgedHere',
        );

        if (cycles < 1) {
          failures.add(
            'the ACT 2 absence window ran zero publish cycles — it proved '
            'nothing about what the app does with a revoked permission',
          );
        }
        if (wedgedHere > 0) {
          failures.add(
            '$wedgedHere of $cycles ACT 2 publish cycle(s) never returned '
            'within ${_publishCycleTimeout.inSeconds}s. A publish path that '
            'hangs with the permission revoked is NOT the same as one that '
            'declines to publish, and this lane may not report the second '
            'when it observed the first. Three known causes, in order of '
            'likelihood: a second permission request raced this one and the '
            'platform cancelled one of them (logcat: "Can request only one '
            'set of permissions at a time"), the system permission dialog was '
            "raised because the grant is not USER_FIXED (check the shell's "
            'Phase 6 read-back), or ACT 2 is running against ACT 1 state '
            'because `pm clear` did not take',
          );
        }
        if (maxPublished > 0) {
          failures.add(
            'the app published location to $maxPublished circle(s) with '
            'ACCESS_FINE_LOCATION revoked',
          );
        }
      }

      debugPrint(kSequenceCompleteMarker);

      // Single terminal assertion. Everything above has already been printed
      // to logcat, so the shell's oracle has a complete window regardless of
      // what happens here.
      expect(
        failures,
        isEmpty,
        reason: 'B5 findings:\n - ${failures.join('\n - ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 13)),
  );
}
