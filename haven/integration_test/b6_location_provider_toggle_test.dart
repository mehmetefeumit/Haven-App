/// B6 drive target — proves what Haven does when the ANDROID OS LOCATION
/// PROVIDER is switched off underneath a live sharing session, and what it
/// does when it comes back (`docs/CI_HARDENING_BACKLOG.md`, Workstream B,
/// item B6: "Location provider toggle | `cmd location set-location-enabled
/// false`").
///
/// ## B6 is not B5
///
/// B5 revokes the APP's runtime permission (`pm revoke`), which reaches
/// `checkPermission()`'s `denied` / `deniedForever` branches. B6 switches
/// the DEVICE-WIDE provider off, which reaches an entirely different gate:
/// `Geolocator.isLocationServiceEnabled()` (Android
/// `LocationManager.isLocationEnabled()`), read by
/// `GeolocatorLocationService.getCurrentLocation()` at
/// `geolocator_location_service.dart:258` and by `getCurrentLocationFresh()`
/// at `:307`, plus the plugin's own mid-stream
/// `LocationServiceDisabledException`. Neither path is reachable from the
/// other scenario, and NEITHER is reachable at all from
/// `FakeLocationService`, whose `isLocationServiceEnabled()` is a hardcoded
/// `true` (`e2e/_lib/fake_location_service.dart:52`). Every other scenario in
/// this repo injects that fake, so before this target the disabled-provider
/// path executed nowhere in CI.
///
/// ## The behaviour this target measures (verified from source first)
///
/// 1. **A stale-cache tail.** `getCurrentLocation()` serves
///    `_lastStreamPosition` whenever the cached GPS FIX TIME is within
///    `kStreamPositionMaxAge` (= `kLocationPublishMaxInterval`, 168 s) —
///    BEFORE it ever consults `isLocationServiceEnabled()`. So for up to
///    168 s after the user switches location off, the publish path keeps
///    succeeding from cache. This target MEASURES that tail rather than
///    assuming it, and only then asserts that publishing has stopped.
/// 2. **Detection.** Past the tail the service layer throws
///    `LocationServiceException`, and the position stream carries the
///    plugin's `LocationServiceDisabledException`
///    (`geolocator_android/lib/src/geolocator_android.dart:247`, raised from
///    `LocationManagerClient.onProviderDisabled`).
/// 3. **Surfacing.** Both app-side listeners of `locationStreamProvider`
///    (`map_page.dart:441` and `map_shell.dart:738`) handle it with
///    `next.whenData(...)`, which DISCARDS the error, and the map's only
///    error overlay is gated on `_obfuscatedLocation == null`
///    (`map_page.dart:568`) — false in every mid-session case. This target
///    asserts the user-visible half anyway: see "Expected red", below.
/// 4. **Recovery.** Re-enabling the provider restores the one-shot
///    `getCurrentPosition` path the publisher depends on. Whether the
///    continuous STREAM also recovers is recorded as evidence, not asserted
///    (the native client calls `removeUpdates` and nulls its provider on
///    disable, and `onProviderEnabled` is an empty method, so a re-subscribe
///    that reuses `GeolocatorAndroid._positionStream` cannot come back).
///
/// ## Expected red — read this before "fixing" the lane
///
/// The SURFACING assertion is expected to FAIL on this lane's first run, and
/// that failure IS the deliverable: today Haven tells the user NOTHING when
/// the OS location provider is switched off mid-session. Do not satisfy it by
/// weakening the check (CLAUDE.md, Testing Requirements #5); satisfy it by
/// rendering the app's OWN existing copy — `mapLocationOffTitle` /
/// `mapLocationOffMessage`, already translated in all 13 locales — when the
/// service is disabled. The check accepts any of the map's existing error
/// strings precisely so it does not dictate a design.
///
/// ## Why the body never throws mid-sequence
///
/// The shell (`tooling/e2e/ci/run-b6-location-provider-toggle.sh`) drives the
/// two `cmd location set-location-enabled` toggles from OUTSIDE the process
/// and waits on markers this file prints. A phase that threw would leave the
/// shell waiting for a marker that can never arrive, burning the lane's whole
/// deadline and reporting a timeout instead of the finding. Every phase
/// therefore RECORDS a verdict marker and continues; the collected verdicts
/// are asserted once, at the end, after both toggles have happened and all
/// evidence is in logcat. The shell's oracle re-derives the same verdicts
/// from the markers independently, so a `flutter drive` that exits 0 on a
/// failed body (see `drive-log-lib.sh`) cannot hide them.
///
/// ## No `locationServiceProvider` override
///
/// Deliberate, and load-bearing: the whole point is to run the REAL
/// `GeolocatorLocationService` against the REAL platform channel. The
/// emulator's GPS is fed by the shell (`adb emu geo fix`, re-issued on a
/// loop), and the shell keeps feeding it THROUGH the disabled window — so a
/// publish that survived the toggle would prove the app ignored the provider
/// state, not that its position source dried up.
///
/// ## Markers
///
/// Owned by THIS file. Change here AND in the shell together, or the lane
/// silently stops finding them.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/l10n/app_localizations.dart';
import 'package:haven/main.dart';
import 'package:haven/src/constants/location.dart'
    show kStreamPositionMaxAge;
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
import 'package:haven/src/providers/location_provider.dart'
    show locationStreamProvider;
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
    show LocationServiceException;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:haven/src/widgets/common/error_display.dart'
    show HavenErrorDisplay;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound, waitUntilAsync;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;

/// Printed once identity, circle and a first successful publish all exist —
/// i.e. the session this lane is about to disturb is genuinely live.
const String kArmedMarker = '[b6] ARMED';

/// Printed with `n=<count>`: the number of circles published to while the
/// provider was ENABLED. The shell PARSES it and requires `>= 1`; a lane that
/// never published with location ON can prove nothing by observing that it
/// does not publish with location OFF.
const String kBaselinePublishedMarker = '[b6] BASELINE_PUBLISHED';

/// Printed with `present=<bool>`: whether the map is ALREADY showing an error
/// surface while everything is healthy. The anti-vacuity check for the
/// surfacing verdict — a `true` here would make a later "surfaced" reading
/// meaningless, so the shell fails the lane on it.
const String kSurfacingBaselineMarker = '[b6] SURFACING_BASELINE';

/// The shell's cue to run `cmd location set-location-enabled false`.
const String kAwaitingDisableMarker = '[b6] AWAITING_DISABLE';

/// Printed once the APP ITSELF observed `isLocationServiceEnabled() == false`
/// — proof the toggle reached the process under test, not merely that adb
/// accepted it.
const String kProviderDisabledMarker = '[b6] PROVIDER_DISABLED_OBSERVED';

/// Printed with `via=<source>` once the app DETECTED the disabled provider
/// (the service layer throwing, and/or the position stream carrying the
/// plugin's `LocationServiceDisabledException`).
const String kDetectedMarker = '[b6] DETECTED';

/// Printed with `tail=<seconds>s checks=<n>` once the publish path has
/// returned zero circles on `<n>` consecutive attempts. `tail` is how long
/// the `kStreamPositionMaxAge` cache kept publishing AFTER the user switched
/// location off — measured, not assumed.
const String kPublishStoppedMarker = '[b6] PUBLISH_STOPPED';

/// The negative twin of [kPublishStoppedMarker]: publishing never stopped
/// inside the bounded window.
const String kPublishNotStoppedMarker = '[b6] PUBLISH_NOT_STOPPED';

/// Printed when the app shows the user SOMETHING about the disabled provider.
const String kSurfacingPresentMarker = '[b6] SURFACING_PRESENT';

/// Printed when it does not. Expected today — see "Expected red" above.
const String kSurfacingAbsentMarker = '[b6] SURFACING_ABSENT';

/// The shell's cue to run `cmd location set-location-enabled true`.
const String kAwaitingReenableMarker = '[b6] AWAITING_REENABLE';

/// Printed once the app observed `isLocationServiceEnabled() == true` again.
const String kProviderReenabledMarker = '[b6] PROVIDER_REENABLED_OBSERVED';

/// Printed with `n=<count>` once publishing works again after re-enabling.
const String kPublishResumedMarker = '[b6] PUBLISH_RESUMED';

/// The negative twin of [kPublishResumedMarker].
const String kPublishNotResumedMarker = '[b6] PUBLISH_NOT_RESUMED';

/// Evidence only (never asserted): the continuous position stream delivered a
/// fresh fix after the provider came back.
const String kStreamRecoveredMarker = '[b6] STREAM_RECOVERED';

/// Evidence only: it did not. See the class doc's point 4 for why this is
/// expected on Android and why it is recorded rather than asserted.
const String kStreamDeadMarker = '[b6] STREAM_DEAD';

/// Closes the capture. Printed unconditionally, before the final assertion,
/// so the shell's oracle always reads a complete window.
const String kSequenceCompleteMarker = '[b6] SEQUENCE_COMPLETE';

/// How long to wait for the shell's `set-location-enabled false` to land.
const Duration _toggleObservationTimeout = Duration(seconds: 90);

/// How long to wait for publishing to stop after the provider goes away.
///
/// Must exceed [kStreamPositionMaxAge] (168 s): until the cached stream fix
/// ages past it, `getCurrentLocation()` never reaches the service-enabled
/// check at all and publishing legitimately continues. 90 s of slack on top
/// covers a loaded CI emulator and the poll granularity.
final Duration _publishStopTimeout =
    kStreamPositionMaxAge + const Duration(seconds: 90);

/// How long to wait for publishing to come back after the provider returns.
/// One cold `getCurrentPosition` on a loaded emulator can take the service's
/// full 30 s timeout, so this allows several attempts.
const Duration _publishResumeTimeout = Duration(seconds: 150);

/// Consecutive zero-publish confirmations required before declaring that
/// publishing has stopped. One reading could be a transient GPS miss; four
/// spaced readings distinguish "stopped" from "flaky".
const int _sustainedZeroChecks = 4;

/// Spacing between the sustained zero-publish confirmations.
const Duration _sustainedCheckSpacing = Duration(seconds: 8);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B6: switching the OS location provider off mid-session stops publishing '
    'and is surfaced to the user; switching it back on recovers',
    (tester) async {
      // `cmd location set-location-enabled` is an Android shell command, and
      // the gate under test (`LocationManager.isLocationEnabled`) is the
      // Android one. iOS has its own scenario (backlog B7).
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b6_location_provider_toggle_test drives the Android '
          '`cmd location set-location-enabled` toggle; skipped on '
          'non-Android runtimes.',
        );
        return;
      }

      // Verdicts collected across the sequence and asserted ONCE at the end,
      // so a failure never strands the shell mid-toggle (see class doc).
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
            'publish.',
      );

      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b6] circleServiceProvider is not Nostr-backed in this run — the '
          'production publish path this target exercises was bypassed.',
        );
      }
      final manager = await circleService.getCircleManagerFfi();

      // A creator-only circle is enough here, and is deliberately simpler
      // than B1's two-user setup: `filterPublishEligibleCircles` and
      // `locationPublisherProvider` both key on `MembershipStatus.accepted`,
      // which `create_circle` stamps on the creator's own row
      // (haven-core/src/circle/manager.rs:380). This lane asserts that the
      // device PUBLISHES, and `publishLocation` resolves only once a relay
      // OK-acked (Security Rule 13), so no second party is needed to make
      // that a delivery claim rather than a liveness one.
      await withFreshSecret(
        () =>
            container.read(identityNotifierProvider.notifier).getSecretBytes(),
        (aliceSecret) => createCircleConfirmed(
          manager: manager,
          relay: relay,
          identitySecretBytes: aliceSecret,
          members: const <MemberKeyPackageFfi>[],
          name: 'B6 Provider Toggle Circle',
          circleType: 'location_sharing',
          relays: <String>[defaultStrfryUrl],
          creatorFallbackRelays: <String>[defaultStrfryUrl],
          label: 'b6',
        ),
      );

      final locationService = container.read(locationServiceProvider);

      /// Runs one production publish cycle and returns the number of circles
      /// it published to. `locationPublisherProvider` swallows every failure
      /// into `0`, which is exactly the signal this lane needs.
      Future<int> publishNow() async {
        container.invalidate(locationPublisherProvider);
        return container.read(locationPublisherProvider.future);
      }

      /// Whether the map is currently showing the user ANY error/off surface.
      ///
      /// Accepts the map's own existing copy in whichever locale the device
      /// runs, plus the shared [HavenErrorDisplay] widget, so the check
      /// states "the user was told something" without dictating the design.
      bool surfacingVisible() {
        final context = tester.element(find.byType(MapShell));
        final l10n = AppLocalizations.of(context);
        return find.text(l10n.mapLocationOffTitle).evaluate().isNotEmpty ||
            find.text(l10n.mapLocationOffMessage).evaluate().isNotEmpty ||
            find.text(l10n.mapLocationErrorTitle).evaluate().isNotEmpty ||
            find.text(l10n.mapLocationUnavailable).evaluate().isNotEmpty ||
            find.byType(HavenErrorDisplay).evaluate().isNotEmpty;
      }

      // ===================================================================
      // Phase 1 — baseline: the provider is ON and the app publishes.
      // ===================================================================
      var baseline = 0;
      try {
        await waitUntilAsync(
          () async {
            baseline = await publishNow();
            return baseline >= 1;
          },
          description: 'a publish cycle reached >= 1 circle with the OS '
              'location provider ENABLED (needs an emulator GPS fix — the '
              'shell seeds one with `adb emu geo fix`)',
          timeout: const Duration(seconds: 150),
          pollInterval: const Duration(seconds: 6),
        );
      } on Object catch (e) {
        failures.add(
          'baseline publish never succeeded (${e.runtimeType}) — with the '
          'provider ON the app must publish, or nothing this lane observes '
          'afterwards can be attributed to the toggle',
        );
      }
      debugPrint('$kBaselinePublishedMarker n=$baseline');

      // Anti-vacuity: if an error surface is ALREADY up while healthy, a
      // later "surfaced" reading proves nothing.
      await tester.pump();
      final baselineSurfacing = surfacingVisible();
      debugPrint('$kSurfacingBaselineMarker present=$baselineSurfacing');
      debugPrint(kArmedMarker);

      // ===================================================================
      // Phase 2 — the shell switches the provider OFF.
      // ===================================================================
      debugPrint(kAwaitingDisableMarker);
      var observedDisabled = false;
      try {
        await waitUntilAsync(
          () async => !await locationService.isLocationServiceEnabled(),
          description: 'the app observed isLocationServiceEnabled() == false '
              'after the shell ran `cmd location set-location-enabled false`',
          timeout: _toggleObservationTimeout,
        );
        observedDisabled = true;
        debugPrint(kProviderDisabledMarker);
      } on Object catch (e) {
        failures.add(
          'the app never observed the provider as disabled '
          '(${e.runtimeType}) — the shell toggle did not reach this process',
        );
      }
      final disabledAt = DateTime.now();

      // --- Detection: does the app KNOW? Two independent sources; either is
      // proof it is not blind, and both are recorded.
      if (observedDisabled) {
        final sources = <String>[];
        try {
          await locationService.getCurrentLocationFresh();
        } on LocationServiceException {
          sources.add('service-layer-throw');
        } on Object catch (e) {
          // Any other failure type still means the fresh read did not
          // silently succeed; record what it was (type only, Rule 8).
          sources.add('fresh-read-${e.runtimeType}');
        }
        try {
          await waitUntilAsync(
            () async => container.read(locationStreamProvider).hasError,
            description: 'locationStreamProvider carried the plugin error',
          );
          sources.add('stream-error');
        } on Object catch (_) {
          // Recorded by omission — the service-layer throw above is the
          // deterministic source; the stream error is timing-dependent.
        }
        if (sources.isEmpty) {
          failures.add(
            'the app never detected the disabled provider: a fresh location '
            'read SUCCEEDED and the position stream reported no error',
          );
        } else {
          debugPrint('$kDetectedMarker via=${sources.join('+')}');
        }
      }

      // --- Publishing must stop. NOT immediately: getCurrentLocation()
      // serves `_lastStreamPosition` while the cached FIX is younger than
      // kStreamPositionMaxAge, ahead of any service-enabled check, so a tail
      // of successful publishes is the documented behaviour. Measure it.
      if (observedDisabled) {
        var consecutiveZeros = 0;
        try {
          await waitUntilAsync(
            () async {
              final n = await publishNow();
              if (n == 0) {
                consecutiveZeros++;
              } else {
                consecutiveZeros = 0;
              }
              return consecutiveZeros >= _sustainedZeroChecks;
            },
            description: 'the publish path returned 0 circles on '
                '$_sustainedZeroChecks consecutive attempts with the '
                'provider disabled',
            timeout: _publishStopTimeout,
            pollInterval: _sustainedCheckSpacing,
          );
          final tail = DateTime.now().difference(disabledAt).inSeconds;
          debugPrint(
            '$kPublishStoppedMarker tail=${tail}s '
            'checks=$_sustainedZeroChecks',
          );
        } on Object catch (e) {
          debugPrint('$kPublishNotStoppedMarker reason=${e.runtimeType}');
          failures.add(
            'publishing did NOT stop within '
            '${_publishStopTimeout.inSeconds}s of the provider being '
            'disabled — the app kept broadcasting location after the user '
            'switched location services off',
          );
        }
      }

      // --- Surfacing. Pump first: any reactive surface needs a frame.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final surfaced = surfacingVisible();
      debugPrint(
        surfaced ? kSurfacingPresentMarker : kSurfacingAbsentMarker,
      );
      if (baselineSurfacing) {
        failures.add(
          'an error surface was ALREADY visible before the provider was '
          'disabled, so the surfacing reading is vacuous — fix the harness '
          'before reading anything into it',
        );
      } else if (!surfaced) {
        failures.add(
          'the disabled provider was NOT surfaced to the user. Both '
          'listeners of locationStreamProvider (map_page.dart:441, '
          'map_shell.dart:738) discard the error with `next.whenData(...)`, '
          'and the map error overlay is gated on `_obfuscatedLocation == '
          'null` (map_page.dart:568), which is false mid-session. Location '
          'sharing stops silently and the map keeps showing the last fix. '
          'See docs/CI_HARDENING_BACKLOG.md B6',
        );
      }

      // ===================================================================
      // Phase 3 — the shell switches the provider back ON.
      // ===================================================================
      debugPrint(kAwaitingReenableMarker);
      var observedReenabled = false;
      try {
        await waitUntilAsync(
          locationService.isLocationServiceEnabled,
          description: 'the app observed isLocationServiceEnabled() == true '
              'after the shell ran `cmd location set-location-enabled true`',
          timeout: _toggleObservationTimeout,
        );
        observedReenabled = true;
        debugPrint(kProviderReenabledMarker);
      } on Object catch (e) {
        failures.add(
          'the app never observed the provider as re-enabled '
          '(${e.runtimeType}) — recovery could not be tested',
        );
      }

      if (observedReenabled) {
        var resumed = 0;
        try {
          await waitUntilAsync(
            () async {
              resumed = await publishNow();
              return resumed >= 1;
            },
            description: 'a publish cycle reached >= 1 circle again after '
                'the provider was re-enabled',
            timeout: _publishResumeTimeout,
            pollInterval: const Duration(seconds: 6),
          );
          debugPrint('$kPublishResumedMarker n=$resumed');
        } on Object catch (e) {
          debugPrint('$kPublishNotResumedMarker reason=${e.runtimeType}');
          failures.add(
            'publishing did NOT resume within '
            '${_publishResumeTimeout.inSeconds}s of the provider being '
            're-enabled — turning location back on left sharing dead for '
            'the rest of the session',
          );
        }

        // Evidence only. The continuous stream is a separate mechanism from
        // the one-shot the publisher uses, and the Android plugin's
        // disable path (`removeUpdates` + `currentLocationProvider = null`,
        // with an EMPTY `onProviderEnabled`) gives it no way back without a
        // re-subscription. Recorded so the lane says which of the two
        // recovered, rather than implying both did.
        var streamBack = false;
        try {
          await waitUntilAsync(
            () async => container.read(locationStreamProvider).hasValue &&
                !container.read(locationStreamProvider).hasError,
            description: 'the position stream delivered again',
            timeout: const Duration(seconds: 45),
            pollInterval: const Duration(seconds: 3),
          );
          streamBack = true;
        } on Object catch (_) {
          // Expected on Android today; see above.
        }
        debugPrint(streamBack ? kStreamRecoveredMarker : kStreamDeadMarker);
      }

      debugPrint(kSequenceCompleteMarker);

      // Single terminal assertion. Everything above has already been printed
      // to logcat, so the shell's oracle has a complete window regardless of
      // what happens here.
      expect(
        failures,
        isEmpty,
        reason: 'B6 findings:\n - ${failures.join('\n - ')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
