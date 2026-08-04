/// B4 drive target — the iOS lane that publishes a **real CoreLocation fix**
/// and proves a peer decrypts those exact coordinates
/// (`docs/CI_HARDENING_BACKLOG.md`, Workstream B, item B4: "iOS real GPS —
/// `simctl privacy grant location` + `simctl location set`").
///
/// ## What was missing before this file
///
/// Every other iOS scenario overrides `locationServiceProvider` with
/// `FakeLocationService` — `e2e_combined.dart:475` and `:5171`,
/// `e2e_profile_sharing.dart:706` — so on the iOS lanes CoreLocation, the
/// authorization path, `AppleSettings`, and the simulator's own location stack
/// are never touched. `run-ios-sim-scenario.sh` says so in its own header. The
/// fake yields a compile-time constant, which means the whole publish path was
/// proven against a value that could never have come from the OS.
///
/// This target overrides **nothing** about location. The mounted `HavenApp`
/// resolves `locationServiceProvider` to the production
/// `GeolocatorLocationService`, which talks to the real CLLocationManager,
/// whose fix is whatever `xcrun simctl location <udid> set <lat>,<lon>` put
/// there. The coordinates asserted at the end are therefore the ones the CI
/// shell chose, carried all the way through geolocator → the MLS encrypt →
/// the hermetic relay → a second peer's decrypt.
///
/// ## The authorization handshake (read before changing the ordering)
///
/// `xcrun simctl privacy <device> grant location <bundle-id>` **requires the
/// app to already be installed** — it resolves the bundle id against the
/// simulator's installed apps — and a grant does NOT survive
/// `simctl uninstall`. A `flutter test` run builds, installs and launches in
/// one step, so there is no gap in it for the shell to grant in.
///
/// The runner (`tooling/e2e/ci/run-b4-ios-real-gps.sh`) therefore does what the
/// B7 auth-tier lane does: `flutter build ios --simulator` once, then
/// uninstall → install → `simctl privacy grant location` → `simctl location
/// set`, and only then delegates the drive to `run-ios-sim-scenario.sh` with
/// `HAVEN_E2E_IOS_SKIP_UNINSTALL=1` so the shared runner's hermetic uninstall
/// cannot erase the grant it just made. Authorization is therefore in place
/// **before the app's first launch**, which is the only ordering that does not
/// depend on a running CLLocationManager observing a live TCC change.
///
/// This file must not defeat that. It checks authorization **before** anything
/// can ask for it: the permission gate below runs before `HavenApp` is pumped,
/// because a mounted `MapShell` reaches `locationPublisherProvider`, whose
/// `getCurrentLocation()` calls `requestPermission()` on a `denied` status —
/// and an un-answerable system prompt on a headless simulator is a hang, not a
/// failure. The gate polls (rather than reading once) purely to absorb
/// CLLocationManager's own start-up latency; a status still ungranted at the
/// deadline means the runner's pre-launch grant did not survive to launch, and
/// [kLocationAuthMissingMarker] says so in the log so the failure is attributed
/// to the install/grant ordering rather than to the app.
///
/// ## Unlike Android, the fix is NOT one-shot
///
/// B3's `adb emu geo fix` injects a single sample into the goldfish GNSS HAL
/// and starts no stream, so that lane needs a re-issue loop.
/// `simctl location &lt;udid&gt; set` is device state that persists until
/// `clear` (or shutdown), and it survives an app re-install because it is not
/// app-scoped. The B4 runner
/// therefore sets it once, and a missing fix here means the simulator never
/// delivered — not that the seed expired.
///
/// ## Why the expected coordinates come from `--dart-define`
///
/// The shell owns the truth. It is the thing that called `simctl location set`,
/// so it is the only party that can state what the OS was told; a constant
/// compiled into this file would drift from the shell's the first time either
/// side was edited, and the assertion would then be proving that Dart agrees
/// with Dart. Absent or unparseable defines fail the test rather than falling
/// back to a default, for the same reason. The names mirror B3's
/// (`HAVEN_B3_GEO_*`) so the two real-GPS lanes read the same way.
///
/// ## The assertions
///
/// In order, each one narrowing where a failure can live:
///
///   1. Location services are enabled and authorization is `whileInUse` or
///      `always` — the real `CLAuthorizationStatus`, not a fake's constant.
///   2. `getCurrentLocationFresh()` — the production one-shot, with NO cached
///      fallback — returns the coordinates `simctl location set` was given.
///      This isolates "the simulator never delivered a fix" from every
///      downstream MLS/relay failure, so the two cannot be confused.
///   3. `locationPublisherProvider` (production, unoverridden, reading the
///      production `GeolocatorLocationService`) publishes to >= 1 circle.
///   4. Bob — a genuinely separate in-process `SyntheticUser` with his own MLS
///      state — decrypts Alice's kind-445 and the DECRYPTED VALUE matches the
///      simulator's coordinates. Not "something was published": the number.
///   5. The decrypted value is NOT `aliceFakeLatitude`/`aliceFakeLongitude`
///      and not `(0, 0)`. Re-introducing a `locationServiceProvider` override
///      here, or an iOS simulator that silently reports the null island, both
///      fail loudly instead of passing as "coordinates arrived".
///
/// ## Markers
///
/// Owned by THIS file — change here AND in
/// `tooling/e2e/ci/run-b4-ios-real-gps.sh` together, or the lane stops finding
/// them (and its out-of-process oracle goes vacuous):
///
///   * [kLocationAuthOkMarker] — real CoreLocation authorization observed.
///   * [kLocationAuthMissingMarker] — it was not, on the first poll. Diagnostic
///     only: it attributes a failure to the pre-launch grant rather than to the
///     app.
///   * [kPublishedMarker] — the production `locationPublisherProvider` reported
///     a non-zero circle count.
///   * [kPeerDecryptMatchMarker] — printed ONLY after every coordinate
///     assertion has passed. The runner requires it in the log, so a drive that
///     exits 0 without reaching the proof (a skip, an early return, a reporter
///     that lied about the outcome) still fails the lane.
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
    show circleServiceProvider;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        CircleWithMembersFfi,
        MemberKeyPackageFfi,
        RelayManagerFfi;
import 'package:haven/src/services/fresh_secret.dart' show withFreshSecret;
import 'package:haven/src/services/geolocator_location_service.dart'
    show GeolocatorLocationService;
import 'package:haven/src/services/location_service.dart'
    show LocationPermissionStatus;
import 'package:haven/src/services/nostr_circle_service.dart'
    show NostrCircleService;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart' show waitForKeyPackage;
import 'e2e/_lib/fake_location_service.dart'
    show aliceFakeLatitude, aliceFakeLongitude;
import 'e2e/_lib/pump_helpers.dart' show pumpUntilFound;
import 'e2e/_lib/scenario_harness.dart' show ScenarioHarness;
import 'e2e/_lib/synthetic_user.dart' show DecryptedCoords, SyntheticUser;
import 'e2e/_lib/test_relay.dart' show TestRelay, defaultStrfryUrl;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed, bytesToHex;

/// Verbatim marker printed once when this drive observes that location
/// authorization was NOT granted before launch. Diagnostic: it attributes the
/// failure to the runner's pre-launch install → grant ordering.
const String kLocationAuthMissingMarker = '[b4] LOCATION_AUTH_MISSING';

/// Verbatim marker printed the instant real CoreLocation authorization is
/// observed.
const String kLocationAuthOkMarker = '[b4] LOCATION_AUTH_OK';

/// Verbatim marker printed once the production `locationPublisherProvider`
/// reports a non-zero circle count.
const String kPublishedMarker = '[b4] PUBLISHED';

/// Verbatim marker printed once the PEER has decrypted a location from Alice
/// whose coordinates match the simulator fix. The lane's deliverable, and the
/// runner's out-of-process proof that the drive actually reached it.
const String kPeerDecryptMatchMarker = '[b4] PEER_DECRYPT_MATCH';

/// Latitude the CI shell passed to `xcrun simctl location <udid> set`.
///
/// No `defaultValue`: an absent define must fail the lane, not silently supply
/// a number to compare against itself.
const String kExpectedLatitudeDefine = String.fromEnvironment(
  'HAVEN_B4_GEO_LAT',
);

/// Longitude the CI shell passed to `xcrun simctl location <udid> set`.
const String kExpectedLongitudeDefine = String.fromEnvironment(
  'HAVEN_B4_GEO_LON',
);

/// Comparison tolerance in degrees, overridable by the runner.
///
/// `1e-5` (~1.1 m) matches B3. It is not a rounding risk here: `simctl location
/// set` hands CoreLocation the exact double it was given — the simulator runs
/// no GNSS solver and adds no noise — so the only way to miss this window is a
/// genuine coordinate-carrying defect.
const String kToleranceDefine = String.fromEnvironment(
  'HAVEN_B4_GEO_TOLERANCE_DEG',
  defaultValue: '1e-5',
);

/// How long the pre-mount permission gate waits for authorization.
///
/// Long enough for the runner's marker-driven re-grant fallback (which polls on
/// a ~2 s cadence) to land and for CLLocationManager to observe it, short
/// enough that a lane whose grant never worked fails with an attributable
/// message rather than burning the whole attempt budget.
const Duration _authWaitBudget = Duration(seconds: 90);

/// How long Bob is given to see and decrypt Alice's kind-445.
const Duration _peerDecryptBudget = Duration(seconds: 120);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'B4: publish a REAL simulator GPS fix and prove a peer decrypts those '
    'exact coordinates',
    (tester) async {
      // Deliberately NOT `markTestSkipped` on a non-iOS runtime. This target is
      // invoked by exactly one lane, which boots a simulator; anywhere else is
      // a harness misconfiguration, and A3b is the standing reminder that a
      // skipped drive-side test is textually indistinguishable from a passing
      // one.
      expect(
        Platform.isIOS,
        isTrue,
        reason:
            'b4_ios_real_gps_test drives the iOS simulator location stack '
            '(simctl privacy + simctl location). It has no meaning on another '
            'platform, and reaching here off-iOS means the lane pointed at the '
            'wrong device.',
      );

      final expectedLatitude = double.tryParse(kExpectedLatitudeDefine);
      final expectedLongitude = double.tryParse(kExpectedLongitudeDefine);
      final tolerance = double.tryParse(kToleranceDefine);
      expect(
        expectedLatitude != null && expectedLongitude != null,
        isTrue,
        reason:
            'HAVEN_B4_GEO_LAT / HAVEN_B4_GEO_LON were not compiled into this '
            'build (got "$kExpectedLatitudeDefine" / '
            '"$kExpectedLongitudeDefine"). These name the coordinates the '
            'runner handed to `simctl location set`; without them this test '
            'has nothing to compare a decrypt against, and defaulting would '
            'make it assert that Dart agrees with Dart. Drive this target '
            'through tooling/e2e/ci/run-b4-ios-real-gps.sh.',
      );
      expect(
        tolerance != null && tolerance > 0,
        isTrue,
        reason:
            'HAVEN_B4_GEO_TOLERANCE_DEG is not a positive number (got '
            '"$kToleranceDefine"). A non-positive tolerance makes the '
            'coordinate comparison unsatisfiable rather than strict.',
      );

      // =====================================================================
      // 1 — Real CoreLocation authorization, BEFORE anything can prompt.
      // =====================================================================
      final locationService = GeolocatorLocationService();

      expect(
        await locationService.isLocationServiceEnabled(),
        isTrue,
        reason:
            'CLLocationManager reports location services disabled on this '
            'simulator. `simctl location set` seeds a fix but cannot enable '
            "the service; check the runner's preflight.",
      );

      await _awaitLocationAuthorization(locationService);

      // =====================================================================
      // 2 — The production one-shot returns the simulator's fix.
      //
      // getCurrentLocationFresh(), not getCurrentLocation(): the latter serves
      // `_lastStreamPosition` when it is warm, so it could report a fix this
      // process obtained some other way. `Fresh` has NO cached fallback — it
      // either gets a live CLLocationManager fix or throws.
      // =====================================================================
      final fix = await locationService.getCurrentLocationFresh();
      // Coordinates are never logged (they are the payload this lane proves is
      // encrypted); only the fact of a fix is.
      debugPrint('[b4] CoreLocation delivered a fresh one-shot fix.');
      expect(
        fix.latitude,
        closeTo(expectedLatitude!, tolerance!),
        reason:
            'the production GeolocatorLocationService one-shot did not return '
            'the latitude the runner set with `simctl location set`. The MLS '
            'pipeline below is not implicated — this is CoreLocation or the '
            'simulator location stack.',
      );
      expect(
        fix.longitude,
        closeTo(expectedLongitude!, tolerance),
        reason:
            'the production GeolocatorLocationService one-shot did not return '
            'the longitude the runner set with `simctl location set`.',
      );

      // =====================================================================
      // 3 — Harness, identity, and the REAL app with NO location override.
      // =====================================================================
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;
      SyntheticUser? bob;

      // Persisted under the PRODUCTION secure-storage key, and it also writes
      // the location-disclosure flags `locationPublisherProvider` gates on.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
      final prefs = await SharedPreferences.getInstance();
      final introSeen = prefs.getBool(kOnboardingIntroSeenKey) ?? false;
      final completed = prefs.getBool(kOnboardingCompletedKey) ?? false;

      try {
        await tester.pumpWidget(
          ProviderScope(
            // The ONLY override, and it is about onboarding, not location:
            // production pre-loads these flags in main.dart's own bootstrap,
            // which pumping HavenApp directly bypasses.
            //
            // There is deliberately NO `locationServiceProvider` override here.
            // That absence is the entire point of this file (backlog B4); a
            // future edit that adds one turns this lane back into a
            // restatement of e2e_combined, and the step-5 assertions below
            // exist to catch exactly that.
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
        // keep the frame queue non-empty and pumpAndSettle would hang.
        await pumpUntilFound(
          tester,
          find.byType(MapShell),
          description: 'MapShell after pumpWidget',
        );

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
              'preSeedIdentityAndSkipOnboarding — nothing below can publish.',
        );

        final circleService = container.read(circleServiceProvider);
        expect(
          circleService,
          isA<NostrCircleService>(),
          reason:
              'circleServiceProvider is not Nostr-backed in this run — the '
              'production publish path this target exercises was bypassed.',
        );
        final CircleManagerFfi aliceManager;
        try {
          aliceManager = await (circleService as NostrCircleService)
              .getCircleManagerFfi();
        } on Object catch (e) {
          // Security Rule 8: runtimeType only — a raw error can carry MLS
          // group ids or storage paths.
          throw StateError(
            '[b4] the foreground circleServiceProvider could not open its '
            'CircleManagerFfi (${e.runtimeType}).',
          );
        }

        // =====================================================================
        // 4 — Bob joins, then Alice publishes through the production provider.
        // =====================================================================
        bob = await SyntheticUser.bob(relay);
        await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

        final relayManager = await RelayManagerFfi.newInstance();
        final CircleCreationResultFfi creation;
        try {
          final bobKp = await relayManager.fetchMemberKeypackage(
            pubkey: bob.pubkeyHex,
          );
          if (bobKp == null) {
            throw StateError(
              '[b4] fetchMemberKeypackage returned null for Bob — his '
              'KeyPackage was not found on the relay.',
            );
          }
          // withFreshSecret owns the fetch -> validate-32-bytes ->
          // scrub-in-finally contract (Security Rule 9).
          creation = await withFreshSecret(
            () => container
                .read(identityNotifierProvider.notifier)
                .getSecretBytes(),
            // Publishes Bob's Welcome AND confirms the staged create
            // (Security Rule 13). An unconfirmed create pins the group in
            // MDK's PendingPublish, where Alice's own kind-445 would buffer
            // forever and this lane would time out in step 5 for a reason that
            // has nothing to do with GPS.
            (aliceSecret) => createCircleConfirmed(
              manager: aliceManager,
              relay: relay,
              identitySecretBytes: aliceSecret,
              members: <MemberKeyPackageFfi>[bobKp],
              name: 'B4 Real GPS Circle',
              circleType: 'location_sharing',
              relays: <String>[defaultStrfryUrl],
              // Bob (a SyntheticUser) advertises no inbox relays, so the
              // Welcome-delivery cascade needs the admin's own relay as a
              // fallback (mirrors the production admin flow).
              creatorFallbackRelays: <String>[defaultStrfryUrl],
              label: 'b4',
            ),
          );
        } finally {
          await relayManager.shutdown();
        }

        final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
        expect(
          bobCircle.members.length,
          greaterThanOrEqualTo(2),
          reason: 'Bob must have joined the circle at the shared epoch.',
        );
        expect(
          bytesToHex(bobCircle.circle.nostrGroupId),
          equals(bytesToHex(creation.circle.nostrGroupId)),
          reason: 'Bob joined a DIFFERENT circle than Alice created.',
        );

        // The app's reactive state never learned about this circle (it was
        // created through CircleManagerFfi directly), so invalidate before the
        // publisher reads the visible set.
        container
          ..invalidate(circlesProvider)
          ..invalidate(locationPublisherProvider);

        // Bound the read: a hung FFI publish would otherwise stall past the
        // step timeout with no attribution.
        final publishedTo = await container
            .read(locationPublisherProvider.future)
            .timeout(
              const Duration(seconds: 120),
              onTimeout: () => throw StateError(
                '[b4] locationPublisherProvider did not complete within 120s. '
                'It reads the production GeolocatorLocationService; a stalled '
                'CLLocationManager one-shot is the first thing to check.',
              ),
            );
        expect(
          publishedTo,
          greaterThanOrEqualTo(1),
          reason:
              'locationPublisherProvider published to no circle. With no '
              'locationServiceProvider override in play, the usual causes are '
              'a lost GPS fix or the location-disclosure gate.',
        );
        debugPrint('$kPublishedMarker n=$publishedTo');

        // =====================================================================
        // 5 — THE PROOF: a peer decrypts, and the VALUE is the simulator's.
        // =====================================================================
        final coords = await _awaitAliceCoordinates(
          bob: bob,
          relay: relay,
          circle: bobCircle,
          alicePubkeyHex: container
              .read(identityProvider)
              .valueOrNull!
              .pubkeyHex,
        );

        expect(
          coords.latitude,
          closeTo(expectedLatitude, tolerance),
          reason:
              "Bob decrypted Alice's location but the LATITUDE is not the "
              'one '
              '`simctl location set` seeded. The MLS round trip worked, so '
              'this is a coordinate-carrying regression (encode, transport, or '
              'decode) — exactly what asserting on presence alone would miss.',
        );
        expect(
          coords.longitude,
          closeTo(expectedLongitude, tolerance),
          reason:
              "Bob decrypted Alice's location but the LONGITUDE is not the "
              'one '
              '`simctl location set` seeded.',
        );

        // Anti-regression oracles. Both failures below would otherwise present
        // as a perfectly healthy "coordinates arrived" run.
        expect(
          coords.latitude == aliceFakeLatitude &&
              coords.longitude == aliceFakeLongitude,
          isFalse,
          reason:
              "the decrypted coordinates are FakeLocationService's "
              'sentinels, '
              'so a locationServiceProvider override is in play and this lane '
              'proved nothing about CoreLocation. Remove the override — the '
              'absence of one is what B4 exists to test.',
        );
        expect(
          coords.latitude == 0.0 && coords.longitude == 0.0,
          isFalse,
          reason:
              'the decrypted coordinates are the null island, the value an iOS '
              'simulator reports when it has no simulated location at all.',
        );

        // Printed LAST, after every coordinate assertion above has passed, so
        // the runner's grep for it is a genuine out-of-process proof that the
        // drive reached the end of the proof rather than merely exiting 0.
        // Deltas, not coordinates: the absolute position is the payload this
        // lane exists to prove is encrypted, and CI logs are uploaded as
        // artifacts.
        debugPrint(
          '$kPeerDecryptMatchMarker '
          'dLat=${(coords.latitude - expectedLatitude).abs()} '
          'dLon=${(coords.longitude - expectedLongitude).abs()} '
          'tol=$tolerance',
        );
      } finally {
        // Best-effort, and never allowed to mask the real verdict: a dispose
        // failure after a passing proof is noise, and after a failing one it
        // would replace the attributable error with its own.
        try {
          await bob?.dispose();
        } on Object catch (e) {
          debugPrint('[b4] bob.dispose failed: ${e.runtimeType}');
        }
        try {
          await relay.dispose();
        } on Object catch (e) {
          debugPrint('[b4] relay.dispose failed: ${e.runtimeType}');
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

/// Blocks until CoreLocation reports a granted authorization status.
///
/// Prints [kLocationAuthMissingMarker] once on the first unauthorized poll so
/// the runner can re-issue `simctl privacy grant location`, then
/// [kLocationAuthOkMarker] the instant authorization is observed.
///
/// Throws a [StateError] naming both grant mechanisms if [_authWaitBudget]
/// elapses — the message has to be actionable, because "permission denied" on
/// a simulator has two very different causes (the pre-launch grant never ran,
/// or it ran and CoreLocation did not observe it).
Future<void> _awaitLocationAuthorization(
  GeolocatorLocationService locationService,
) async {
  final deadline = DateTime.now().add(_authWaitBudget);
  var announcedMissing = false;
  var last = LocationPermissionStatus.notDetermined;

  while (DateTime.now().isBefore(deadline)) {
    last = await locationService.checkPermission();
    if (last == LocationPermissionStatus.whileInUse ||
        last == LocationPermissionStatus.always) {
      debugPrint('$kLocationAuthOkMarker status=$last');
      return;
    }
    if (!announcedMissing) {
      announcedMissing = true;
      // The runner greps for this. Never call requestPermission() here: on a
      // headless simulator the system prompt has no one to answer it.
      debugPrint('$kLocationAuthMissingMarker status=$last');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  throw StateError(
    '[b4] CoreLocation authorization never reached whileInUse/always within '
    '${_authWaitBudget.inSeconds}s (last status: $last). Either the '
    "runner's "
    'pre-launch `simctl privacy grant location` did not apply to this bundle '
    '(it requires the app to be INSTALLED — see run-b4-ios-real-gps.sh), or '
    'it applied and a running CLLocationManager did not observe the change, '
    'in which case the pre-launch ordering is the fix, not a longer wait.',
  );
}

/// Drains kind-445 events for [circle] until Alice's location decrypts, and
/// returns the decrypted coordinates.
///
/// Accumulates across drain rounds because Rust-side dedup means a given event
/// only yields a non-null result on the first round it decrypts (see
/// `SyntheticUser.drainPendingCommits`), so a single round that arrives before
/// the publish has landed would otherwise poison every later round.
Future<DecryptedCoords> _awaitAliceCoordinates({
  required SyntheticUser bob,
  required TestRelay relay,
  required CircleWithMembersFfi circle,
  required String alicePubkeyHex,
}) async {
  final wanted = alicePubkeyHex.toLowerCase();
  final accumulated = <String, DecryptedCoords>{};
  final deadline = DateTime.now().add(_peerDecryptBudget);
  var rounds = 0;

  while (DateTime.now().isBefore(deadline)) {
    rounds += 1;
    final summary = await bob.drainPendingCommits(relay: relay, circle: circle);
    accumulated.addAll(summary.decryptedLocations);
    final found = accumulated[wanted];
    if (found != null) {
      debugPrint(
        "[b4] Bob decrypted Alice's location after $rounds round(s).",
      );
      return found;
    }
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  throw StateError(
    '[b4] Bob never decrypted a location from Alice within '
    '${_peerDecryptBudget.inSeconds}s ($rounds drain rounds; senders seen: '
    '${accumulated.length}). The production publisher reported success, so '
    'look at the relay round trip or MLS epoch convergence rather than at the '
    'GPS stack — steps 1-2 already proved CoreLocation delivered the fix.',
  );
}
