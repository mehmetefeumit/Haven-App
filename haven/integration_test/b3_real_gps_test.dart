/// B3 drive target — proves Haven publishes a REAL OS-delivered GPS fix and
/// that a PEER decrypts those exact coordinates
/// (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B3: "Android real
/// GPS — no `locationServiceProvider` override; `pm grant`;
/// `adb emu geo fix`; assert peer decrypt").
///
/// ## What was missing, precisely
///
/// Every other multi-party scenario injects
/// [FakeLocationService][fake] through a `locationServiceProvider` override
/// (`e2e_combined.dart:475`, `e2e_profile_sharing.dart:706`), so the
/// geolocator plugin, the Android runtime-permission branch and the platform
/// location stack are never on the path — the "GPS fix" is a Dart constant
/// handed to `publishLocation`.
///
/// `b1_fgs_live_foreground_test.dart` closed HALF of that gap first: it
/// already declines the override and its shell already seeds
/// `adb emu geo fix`. But B1's oracle is the foreground service's
/// `[BackgroundTask] Published to N/M` logcat marker — it proves that a
/// publish HAPPENED, never WHAT was published, and its peer (Bob) is
/// disposed before the proof window even opens. So no lane anywhere asserts
/// that the bytes a peer decrypts are the coordinates the operating system
/// actually delivered. A publish path that read a stale, zeroed or
/// wrong-hemisphere fix would be green in every lane in this repo.
///
/// This target closes that half. One continuous chain, each link asserted:
///
///   `adb emu geo fix` → goldfish GNSS HAL → Android `LocationManager` →
///   geolocator plugin → `GeolocatorLocationService` →
///   `locationPublisherProvider` → MLS encrypt → kind-445 on the hermetic
///   relay → the PEER's own `CircleManagerFfi.decryptLocation…` → the
///   coordinates compared, numerically, against what was injected.
///
/// ## Why there is no `locationServiceProvider` override here
///
/// That is the entire point of the lane, so it is asserted rather than
/// assumed: checkpoint A2 requires `locationServiceProvider` to resolve to a
/// real [GeolocatorLocationService], and the final assertion additionally
/// requires the decrypted coordinates to differ from the
/// [aliceFakeLatitude]/[aliceFakeLongitude] sentinels. A future override
/// added "to stabilise the lane" therefore fails loudly instead of quietly
/// converting this proof back into the tautology it was built to replace.
///
/// ## Where the expected coordinates come from
///
/// The shell (`tooling/e2e/ci/run-b3-real-gps.sh`) chooses the coordinates,
/// injects them with `adb emu geo fix`, and the SAME values are baked into
/// this APK as `--dart-define`s by
/// `tooling/e2e/ci/build-b3-real-gps-apk.sh` — both read one job-level env
/// pair, so there is exactly one source of truth. The defines carry NO
/// default: an absent value fails checkpoint A0 rather than silently
/// asserting against a stale constant, which would be a lane that passes
/// while measuring nothing.
///
/// The chosen point is a public landmark in the SOUTHERN and WESTERN
/// hemispheres, deliberately: `adb emu geo fix` serialises through NMEA,
/// where latitude and longitude carry an `S`/`W` hemisphere character rather
/// than a sign, so a sign-dropping defect anywhere in the chain shows up as
/// a gross mismatch instead of passing on a positive-quadrant point.
///
/// ## Tolerance
///
/// The comparison is `closeTo(expected, tolerance)` with a default tolerance
/// of 1e-5 degrees (~1.1 m). It is not zero because the injection is
/// quantised: the emulator console encodes the position as NMEA
/// degrees-and-decimal-minutes and the HAL parses it back to a `double`.
/// Even the coarsest historical format (4-decimal minutes) quantises to
/// 1.7e-6 degrees, comfortably inside 1e-5, while 1e-5 is still four orders
/// of magnitude tighter than the distance to any other coordinate any lane
/// in this repo uses — so the assertion identifies the injected point
/// uniquely and cannot be satisfied by a fallback, a sentinel or a zero fix.
///
/// ## Privacy note on the assertions
///
/// A failing `closeTo` prints the observed value, so a mismatch puts a
/// coordinate in the drive log (uploaded as a CI artifact). That is
/// acceptable ONLY because the coordinates are a hardcoded public landmark
/// injected by CI — the same posture `run-b1-fgs-publish.sh` documents for
/// its `dumpsys location` dump. The success path never prints coordinates:
/// it prints the DELTA, which is what a first run needs in order to
/// calibrate the tolerance. Never point this lane at a value derived from a
/// real device or person.
///
/// ## Markers
///
/// Owned by THIS file — change here AND in the shell together, or the lane
/// silently stops finding them:
///
///   * [kRealFixMarker] — the production location service returned a fix
///     matching the injected point, i.e. the OS half of the chain works.
///   * [kPublishedMarker] — the production `locationPublisherProvider`
///     reported publishing to `n>=1` circle(s).
///   * [kPeerDecryptMarker] — the PEER decrypted a location from Alice whose
///     coordinates match the injected point. This is the lane's deliverable.
///
/// [fake]: e2e/_lib/fake_location_service.dart
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/main.dart';
import 'package:haven/src/pages/map_shell.dart';
import 'package:haven/src/providers/circles_provider.dart'
    show circlesProvider;
import 'package:haven/src/providers/identity_provider.dart'
    show identityNotifierProvider, identityProvider;
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
import 'package:haven/src/rust/api.dart'
    show CircleCreationResultFfi, MemberKeyPackageFfi, RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/geolocator_location_service.dart'
    show GeolocatorLocationService;
import 'package:haven/src/services/location_service.dart'
    show LocationPermissionStatus, Position;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show aliceFakeLatitude, aliceFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound, waitUntilAsync;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show DecryptedCoords, SyntheticUser;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;

/// Verbatim marker printed once the PRODUCTION location service has returned
/// a fix matching the `adb emu geo fix` injection — the operating-system half
/// of the chain.
const String kRealFixMarker = '[b3] REAL_FIX_OBSERVED';

/// Verbatim marker printed with the number of circles the PRODUCTION
/// `locationPublisherProvider` published to (`[b3] PUBLISHED n=<N>`).
const String kPublishedMarker = '[b3] PUBLISHED';

/// Verbatim marker printed once the PEER has decrypted a location from Alice
/// whose coordinates match the injected fix. The lane's deliverable.
const String kPeerDecryptMarker = '[b3] PEER_DECRYPT_MATCH';

/// Latitude injected into the emulator by the shell, baked in at build time.
///
/// No `defaultValue`: see the library doc's "Where the expected coordinates
/// come from".
const String _injectedLatRaw = String.fromEnvironment('HAVEN_B3_GEO_LAT');

/// Longitude injected into the emulator by the shell, baked in at build time.
const String _injectedLonRaw = String.fromEnvironment('HAVEN_B3_GEO_LON');

/// Comparison tolerance in degrees. See the library doc's "Tolerance".
const String _toleranceRaw = String.fromEnvironment(
  'HAVEN_B3_GEO_TOLERANCE_DEG',
  defaultValue: '1e-5',
);

/// How long the OS is given to deliver the injected fix.
///
/// `adb emu geo fix` is a ONE-SHOT injection into the goldfish GNSS HAL — it
/// starts no stream — so the shell re-issues it on a short loop and this
/// budget must span several of those re-issues plus geolocator's own 30 s
/// one-shot `timeLimit`.
const Duration _fixWaitTimeout = Duration(seconds: 150);

/// How long the peer is given to observe and decrypt Alice's kind-445.
const Duration _peerDecryptTimeout = Duration(seconds: 120);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B3: a REAL emulator GPS fix reaches a peer, decrypted, unchanged',
    (tester) async {
      // `adb emu geo fix` is an Android-emulator console command and the
      // permission model under test is Android's. iOS real GPS is B4
      // (`simctl location set`), a separate lane.
      if (!Platform.isAndroid) {
        markTestSkipped(
          'b3_real_gps_test drives the Android emulator GPS + runtime '
          'permission path; skipped on non-Android runtimes.',
        );
        return;
      }

      // --- Checkpoint A0: the injected coordinates are actually known here.
      // A missing define would otherwise leave this lane asserting against
      // whatever a default happened to be — green while measuring nothing.
      expect(
        _injectedLatRaw,
        isNotEmpty,
        reason: '[b3] --dart-define=HAVEN_B3_GEO_LAT was not baked into this '
            'APK. Without it this lane cannot know what the shell injected, '
            'so it must not run. Build via '
            'tooling/e2e/ci/build-b3-real-gps-apk.sh.',
      );
      expect(
        _injectedLonRaw,
        isNotEmpty,
        reason: '[b3] --dart-define=HAVEN_B3_GEO_LON was not baked into this '
            'APK (see HAVEN_B3_GEO_LAT above).',
      );
      final expectedLat = double.parse(_injectedLatRaw);
      final expectedLon = double.parse(_injectedLonRaw);
      final tolerance = double.parse(_toleranceRaw);
      expect(
        tolerance,
        greaterThan(0),
        reason: '[b3] a non-positive tolerance would make the coordinate '
            'comparison unsatisfiable (or vacuous).',
      );

      // --- Harness: Rust bridge, in-memory keyring, hermetic relay override.
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice = the PRODUCTION identity under the production secure-storage
      // key. `preSeedIdentityAndSkipOnboarding` also pre-accepts the location
      // prominent-disclosure flags, which `locationPublisherProvider` gates
      // on before it will read GPS at all.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;

      // Mount the REAL app. The ONLY override is the onboarding controller
      // (production pre-loads it in main.dart's bootstrap, which pumping
      // HavenApp directly bypasses). `locationServiceProvider` is
      // deliberately, assertedly untouched — see the library doc.
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
      // pumpUntilFound, not pumpAndSettle — MapShell's periodic timers keep
      // the frame queue non-empty and pumpAndSettle would hang.
      await pumpUntilFound(
        tester,
        find.byType(MapShell),
        description: 'MapShell after pumpWidget',
      );

      final container = ProviderScope.containerOf(
        tester.element(find.byType(HavenApp)),
        listen: false,
      );

      // --- Checkpoint A1: identity resolved.
      await container.read(identityProvider.future);
      final identity = container.read(identityProvider).valueOrNull;
      expect(
        identity,
        isNotNull,
        reason: '[b3] identityProvider resolved to null after '
            'preSeedIdentityAndSkipOnboarding.',
      );
      final alicePubkeyHex = identity!.pubkeyHex.toLowerCase();

      // --- Checkpoint A2: the location service is the PRODUCTION one.
      // Structural proof that no `locationServiceProvider` override is in
      // play; the sentinel check at the end is the behavioural twin.
      final locationService = container.read(locationServiceProvider);
      expect(
        locationService,
        isA<GeolocatorLocationService>(),
        reason: '[b3] locationServiceProvider did not resolve to the real '
            'GeolocatorLocationService — something installed an override, '
            'which removes the geolocator plugin, the runtime-permission '
            'branch and the OS location stack from the path this lane '
            'exists to exercise.',
      );

      // --- Checkpoint A3: the runtime permission the shell `pm grant`ed is
      // genuinely held, and the platform location provider is enabled.
      // Asserted from inside the app because `pm grant`'s exit code is not
      // authoritative (a rejected grant still exits 0), and because a
      // location-disabled emulator would otherwise present as an
      // unattributed fix timeout at A4.
      final permission = await locationService.checkPermission();
      expect(
        permission,
        anyOf(
          LocationPermissionStatus.whileInUse,
          LocationPermissionStatus.always,
        ),
        reason: '[b3] the app does not hold a usable location permission '
            '(got $permission). The shell pre-grants ACCESS_FINE_LOCATION / '
            'ACCESS_COARSE_LOCATION with `pm grant`; a rejected grant still '
            'exits 0, so this is the authoritative read.',
      );
      expect(
        await locationService.isLocationServiceEnabled(),
        isTrue,
        reason: '[b3] the platform location provider is disabled on this '
            'emulator, so no `adb emu geo fix` can ever be delivered.',
      );

      // --- Checkpoint A4: the OS actually delivers the injected fix.
      //
      // Bounded and polled rather than read once: the injection is one-shot
      // (the HAL keeps no stream between `geo fix` calls), so the first read
      // can legitimately land between re-issues. Failing HERE attributes the
      // problem to the emulator/GPS half of the chain instead of surfacing
      // it 60 s later as "the peer never saw a location".
      Position? observed;
      await waitUntilAsync(
        () async {
          try {
            final position = await locationService.getCurrentLocationFresh();
            if ((position.latitude - expectedLat).abs() <= tolerance &&
                (position.longitude - expectedLon).abs() <= tolerance) {
              observed = position;
              return true;
            }
            debugPrint(
              '[b3] fix seen but off target by '
              'dLat=${(position.latitude - expectedLat).abs()} '
              'dLon=${(position.longitude - expectedLon).abs()} '
              '(tolerance $tolerance) — retrying.',
            );
            return false;
          } on Object catch (e) {
            // Rule 8: runtimeType only.
            debugPrint('[b3] no fix yet (${e.runtimeType}) — retrying.');
            return false;
          }
        },
        description: 'the production GeolocatorLocationService returned a '
            'fix matching the coordinates the shell injected with '
            '`adb emu geo fix`',
        timeout: _fixWaitTimeout,
        pollInterval: const Duration(seconds: 3),
      );
      final osFix = observed!;
      // Delta, never the coordinates — see the library doc's privacy note.
      debugPrint(
        '$kRealFixMarker dLat=${(osFix.latitude - expectedLat).abs()} '
        'dLon=${(osFix.longitude - expectedLon).abs()} '
        'tolerance=$tolerance',
      );

      // --- Build a genuine 2-member circle to publish into.
      final circleService = container.read(circleServiceProvider);
      if (circleService is! NostrCircleService) {
        throw StateError(
          '[b3] circleServiceProvider is not Nostr-backed in this run — the '
          'production publish path was bypassed.',
        );
      }
      final aliceManager = await circleService.getCircleManagerFfi();

      // Bob is a genuinely separate peer: his own TestUser at his own temp
      // data directory, hence his own canonical MLS session path (Rule 14),
      // his own MDK state and his own keystore. He decrypts with nothing but
      // what the group gave him.
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
            '[b3] fetchMemberKeypackage returned null for Bob — his '
            'KeyPackage was not found on the relay.',
          );
        }
        creation = await withFreshSecret(
          () => container
              .read(identityNotifierProvider.notifier)
              .getSecretBytes(),
          // Rule 13: publishes Bob's Welcome and CONFIRMS the staged create.
          // An unconfirmed create pins the group in MDK PendingPublish, where
          // every kind-445 buffers forever.
          (aliceSecret) => createCircleConfirmed(
            manager: aliceManager,
            relay: relay,
            identitySecretBytes: aliceSecret,
            members: <MemberKeyPackageFfi>[bobKp],
            name: 'B3 Real GPS Circle',
            circleType: 'location_sharing',
            relays: <String>[defaultStrfryUrl],
            creatorFallbackRelays: <String>[defaultStrfryUrl],
            label: 'b3',
          ),
        );
      } finally {
        await relayManager.shutdown();
      }

      if (!creation.welcomeEvents.any(
        (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
      )) {
        throw StateError('[b3] createCircle produced no gift-wrap for Bob.');
      }

      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      expect(
        bobCircle.members.length,
        greaterThanOrEqualTo(2),
        reason: '[b3] Bob must have joined at the shared epoch, or he cannot '
            'decrypt anything Alice sends.',
      );

      // The app's reactive state never learned about this circle (it was
      // created through CircleManagerFfi directly). Production fidelity only
      // — locationPublisherProvider reads getVisibleCircles() itself.
      container.invalidate(circlesProvider);

      // A cursor, so the drain below can never be satisfied by an event that
      // predates the publish under test.
      final publishFloor = DateTime.now().subtract(
        const Duration(seconds: 5),
      );

      // --- THE SEND HALF: the PRODUCTION publisher, which reads GPS itself.
      //
      // `refresh`, not `read`: MapShell reads this provider during startup
      // (map_shell.dart:301), so by now it may hold a cached `0` from before
      // the circle existed. Refresh forces a real re-execution, and with it a
      // real `locationService.getCurrentLocation()` call.
      final publishedTo = await container.refresh(
        locationPublisherProvider.future,
      );
      debugPrint('$kPublishedMarker n=$publishedTo');
      expect(
        publishedTo,
        greaterThanOrEqualTo(1),
        reason: '[b3] the production locationPublisherProvider published to '
            'no circle. Either the GPS read it performs itself failed (A4 '
            'proves the OS can answer, so suspect the publish-path read), or '
            'the circle was not eligible.',
      );

      // --- THE RECEIVE HALF: the PEER decrypts, and the coordinates must be
      // the ones the operating system delivered.
      DecryptedCoords? peerCoords;
      await waitUntilAsync(
        () async {
          final summary = await bob.drainPendingCommits(
            relay: relay,
            circle: bobCircle,
            since: publishFloor,
          );
          final found = summary.decryptedLocations[alicePubkeyHex];
          if (found != null) {
            peerCoords = found;
            return true;
          }
          return false;
        },
        description: 'the peer decrypted a kind-445 location from Alice',
        timeout: _peerDecryptTimeout,
        pollInterval: const Duration(seconds: 3),
      );
      final decrypted = peerCoords!;

      // ===================================================================
      // THE ASSERTION. Not "something was published" — the VALUE the peer
      // recovered, compared against what `adb emu geo fix` injected.
      // ===================================================================
      expect(
        decrypted.latitude,
        closeTo(expectedLat, tolerance),
        reason: '[b3] the peer decrypted a latitude that is not the one '
            'injected into the emulator GPS. The publish path did not carry '
            'the real OS fix end to end.',
      );
      expect(
        decrypted.longitude,
        closeTo(expectedLon, tolerance),
        reason: '[b3] the peer decrypted a longitude that is not the one '
            'injected into the emulator GPS (see the latitude reason).',
      );

      // Distinctness floors. `closeTo` alone would also be satisfied if the
      // injected point were itself degenerate; these pin that it is not, and
      // that the fake this lane exists to bypass was genuinely bypassed.
      expect(
        decrypted.latitude.abs() + decrypted.longitude.abs(),
        greaterThan(1e-3),
        reason: '[b3] the peer decrypted (0, 0) — the classic "no fix" '
            'value, not a real GPS position.',
      );
      expect(
        (decrypted.latitude - aliceFakeLatitude).abs() +
            (decrypted.longitude - aliceFakeLongitude).abs(),
        greaterThan(1e-3),
        reason: '[b3] the peer decrypted the FakeLocationService sentinel. '
            'Some override put the fake back on the publish path, which is '
            'exactly what this lane exists to prevent.',
      );

      // Delta only — never the coordinates (library doc, privacy note).
      debugPrint(
        '$kPeerDecryptMarker dLat=${(decrypted.latitude - expectedLat).abs()} '
        'dLon=${(decrypted.longitude - expectedLon).abs()} '
        'tolerance=$tolerance',
      );

      // Best-effort teardown. Failures here are not evidence about B3.
      try {
        await bob.dispose();
        await relay.dispose();
      } on Object catch (_) {
        // Ignored deliberately.
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
