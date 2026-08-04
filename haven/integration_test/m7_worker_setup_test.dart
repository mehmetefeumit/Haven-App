/// Phase-A setup target for the `e2e-background-catchup` runtime-proof lane
/// (`docs/M7_BACKGROUND_SHARING.md` D6 + AMENDMENTS A4/A5).
///
/// This target does NOT assert anything about the WorkManager worker itself —
/// it cannot: the worker runs in a SEPARATE process the shell force-runs
/// AFTER this drive exits (`tooling/e2e/ci/run-m7-background-catchup.sh`
/// Phase A). Its whole job is to leave the app in the ARMED state the shell
/// then wakes:
///
///   1. a REAL Nostr identity (Alice) persisted to secure storage under the
///      production key `haven.nostr.identity`, so the worker's separate-process
///      isolate reads it back;
///   2. a REAL MLS circle (Alice admin, Bob member) whose `circles.db` /
///      `haven_mdk.db` live at the PRODUCTION data directory the worker
///      resolves via `PathProviderDataDirectory` — so the worker opens the
///      SAME database this drive created;
///   3. ONE kind-445 peer location published by a `SyntheticUser` (Bob) to the
///      CI relay — the update the worker's receive-only sweep would decrypt;
///   4. `kBackgroundSharingKey = true` in the REAL (on-disk) SharedPreferences,
///      so the worker's consent gate passes;
///   5. a registered ~15-min WorkManager periodic task
///      ([registerBackgroundCatchup]), whose persisted callback handle points
///      at the production `callbackDispatcher`.
///
/// ## A5 — REAL platform keyring (feasibility-critical; read before editing)
///
/// The worker is a **separate process lifecycle** (WorkManager starts a fresh
/// process after `am kill`). MDK reads the `circles.db` encryption key from the
/// platform credential store. If this target let the `_lib` harness install the
/// *in-memory* keyring (`useInMemoryKeyringForTest`, which `TestUser` installs
/// process-globally and which dies with THIS drive process), the worker could
/// never read the key and never open the database.
///
/// The keyring backend is a process-global first-installed-wins latch
/// (`KEYRING_INIT: Mutex<Option<()>>` in `rust_builder/src/api.rs`):
/// `initKeyringStore()` and `useInMemoryKeyringForTest()` share it, and
/// whichever runs FIRST wins (the loser no-ops). This target therefore calls
/// `RustLib.init()` + `initKeyringStore()` (the real platform keyring store)
/// **before** `ScenarioHarness.bootstrap()`, so the harness's later
/// `useInMemoryKeyringForTest()` is a harmless no-op and Alice's database is
/// encrypted with a key that persists in the Android Keystore for the cold
/// worker process to read. Real-keyring viability on the AVD is proven by the
/// green `integration_test/keyring_test.dart`.
///
/// ## Cross-process relay opt-in (why Phase A can assert DELIVERY)
///
/// The debug-only `ws://` loopback opt-in (`allowWsLoopbackForTest`, the
/// `ALLOW_WS_LOOPBACK_FOR_TEST` OnceLock) is ALSO process-global — but, unlike
/// the keyring, it has NO on-disk / persistent form, so it cannot be inherited
/// from this drive process. Until 2026-08-03 the cold worker therefore rejected
/// the plaintext `ws://` CI relay stored in the circle
/// (`validate_single_relay_url`) and its sweep returned `locations=0`,
/// `relayErrors=1` — the lane could only assert bootstrap
/// (`docs/CI_HARDENING_BACKLOG.md` B2).
///
/// [registerM7CiOneOffCatchup] now also registers `m7CiCallbackDispatcher`,
/// which installs the opt-in IN the cold worker process and then runs the
/// production wake body unmodified. Bob's seeded location below is
/// consequently not just realistic history — it is the peer update Phase A
/// hard-asserts the background wake decrypted (`locations>=1` +
/// `relayErrors=0`, with `M7_REQUIRE_DECRYPT` now ON in CI).
///
/// This target intentionally NEVER mounts `MapShell`, so no foreground poller
/// consumes the synthetic location before the worker runs (plan D6).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart' show kBackgroundSharingKey;
import 'package:haven/src/providers/live_sync_provider.dart'
    show backgroundCatchupEnabled;
import 'package:haven/src/rust/api.dart'
    show
        CircleCreationResultFfi,
        CircleManagerFfi,
        MemberKeyPackageFfi,
        NostrIdentityManager,
        RelayManagerFfi,
        initKeyringStore;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_catchup_worker.dart'
    show registerBackgroundCatchup;
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleConfirmed;
import 'e2e/_lib/coordination.dart';
import 'e2e/_lib/m7_worker_ci_oneoff.dart' show registerM7CiOneOffCatchup;
import 'e2e/_lib/scenario_harness.dart';
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart';

/// Sentinel coordinates for Bob's seeded location. Non-identifying; never
/// logged (the kind-445 is MLS-encrypted on the wire — see `SyntheticUser`).
const double _bobLatitude = 40.7128;
const double _bobLongitude = -74.006;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets (not bare test): only a testWidgets body's failure is recorded
  // by the integration binding and can turn `flutter drive` red. This body
  // pumps no widget tree — it drives the FFI + relay directly, exactly like
  // keyring_test.dart — so `tester` is intentionally unused.
  testWidgets(
    'M7 setup: arm the WorkManager catch-up worker (real keyring, seeded peer)',
    (tester) async {
      // Guard: this target only makes sense with the flag ON. A rolled-back
      // build would register nothing and the lane would prove nothing.
      expect(
        backgroundCatchupEnabled,
        isTrue,
        reason: 'm7_worker_setup_test requires backgroundCatchupEnabled=true '
            '(M7-E). Remove the e2e-background-catchup lane if rolling back.',
      );

      // --- A5: install the REAL platform keyring FIRST -------------------
      // Claim the process-global KEYRING_INIT latch with the real Android
      // keyring BEFORE ScenarioHarness.bootstrap() calls
      // useInMemoryKeyringForTest() (which then no-ops). This is what lets the
      // cold worker process read Alice's circles.db key from the Keystore.
      try {
        await RustLib.init();
      } on Object {
        // Bridge already up on this engine (a prior init) — tolerate and let a
        // genuine failure surface at the first FFI call below.
      }
      await initKeyringStore();

      // Harness: installs the ws:// loopback opt-in + the relay override for
      // THIS drive process and opens a strfry probe socket. Its
      // useInMemoryKeyringForTest() is now a no-op (real keyring latched).
      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // --- Alice = the production identity -------------------------------
      // Persist Alice's identity to secure storage under the PRODUCTION key so
      // the worker's separate-process isolate reads it back, then load it
      // in-process for createCircle.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
      final aliceIdentity = await NostrIdentityManager.newInstance();
      await aliceIdentity.loadFromBytes(secretBytes: aliceSeed);

      // Alice's CircleManagerFfi at the PRODUCTION data directory — the exact
      // path the worker resolves — so the worker opens the SAME database.
      final dataDir =
          await const PathProviderDataDirectory().getDataDirectory();
      final aliceManager = await CircleManagerFfi.newInstance(
        dataDir: dataDir,
        identitySecretBytes: aliceSeed,
      );

      // --- Bob = in-process synthetic peer -------------------------------
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);

      // Alice fetches Bob's KeyPackage (RelayManagerFfi, not CircleManagerFfi)
      // and creates a 2-member circle whose stored relay is the CI relay.
      final relayManager = await RelayManagerFfi.newInstance();
      final bobKp =
          await relayManager.fetchMemberKeypackage(pubkey: bob.pubkeyHex);
      if (bobKp == null) {
        throw StateError(
          '[m7-setup] fetchMemberKeypackage returned null for Bob — his '
          'KeyPackage was not found on the relay.',
        );
      }

      final aliceSecret = await aliceIdentity.getSecretBytes();
      // Publishes Bob's gift-wrapped Welcome so he can accept over the relay,
      // then CONFIRMS the staged create (Security Rule 13) — an unconfirmed
      // create pins the group in MDK's `PendingPublish`, where every inbound
      // kind-445 buffers forever. See `createCircleConfirmed`'s doc.
      final CircleCreationResultFfi creation;
      try {
        creation = await createCircleConfirmed(
          manager: aliceManager,
          relay: relay,
          identitySecretBytes: aliceSecret,
          members: <MemberKeyPackageFfi>[bobKp],
          name: 'M7 Catch-up Circle',
          circleType: 'location_sharing',
          relays: <String>[defaultStrfryUrl],
          // Bob (a SyntheticUser) advertises no inbox relays, so the
          // Welcome-delivery cascade needs the admin's own relay as a fallback
          // (mirrors the production admin flow / the FE-2 scenario).
          creatorFallbackRelays: <String>[defaultStrfryUrl],
          label: 'm7-setup',
        );
      } finally {
        for (var i = 0; i < aliceSecret.length; i++) {
          aliceSecret[i] = 0;
        }
      }

      if (!creation.welcomeEvents.any(
        (e) => e.recipientPubkey.toLowerCase() == bob.pubkeyHex.toLowerCase(),
      )) {
        throw StateError(
          '[m7-setup] createCircle produced no gift-wrap for Bob.',
        );
      }

      // Bob accepts (Welcome → MDK state) — now at the shared MLS epoch.
      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);

      // Bob publishes ONE location: the peer update the worker would decrypt.
      await bob.publishLocation(
        circle: bobCircle,
        latitude: _bobLatitude,
        longitude: _bobLongitude,
        relay: relay,
      );
      // Confirm the kind-445 is genuinely on the wire before we arm the worker.
      await waitForGroupMessage(
        relay: relay,
        nostrGroupIdHex: bytesToHex(bobCircle.circle.nostrGroupId),
      );

      // --- Arm the worker ------------------------------------------------
      // REAL (on-disk) prefs — the worker's separate process reads these.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, true);

      // Register the ~15-min WorkManager periodic task (production path).
      await registerBackgroundCatchup();

      // ALSO enqueue a CI-only ONE-OFF task (in addition to, never instead
      // of, the periodic task above). A force-stopped PERIODIC task
      // reschedules to its next ~15-min window instead of running when the
      // shell force-runs it cold (`am kill` + `adb shell cmd jobscheduler
      // run`) — a ONE-OFF task is re-enqueued to run ASAP instead, which is
      // what actually lets the shell boot a cold worker. See
      // m7_worker_ci_oneoff.dart for the full rationale.
      await registerM7CiOneOffCatchup();

      // Sanity asserts so a broken setup fails THIS drive (red) rather than
      // producing a green-but-unarmed state the shell would then mis-diagnose.
      expect(
        bobCircle.members.length,
        greaterThanOrEqualTo(2),
        reason: 'Bob must have joined the circle at the shared epoch.',
      );
      expect(prefs.getBool(kBackgroundSharingKey), isTrue);

      // Best-effort teardown of DRIVE-process helpers only. Deliberately does
      // NOT touch Alice's identity, prefs, or data dir — that armed state must
      // survive for the worker.
      try {
        await relayManager.shutdown();
        await bob.dispose();
        await relay.dispose();
      } on Object catch (_) {
        // Cleanup is best-effort; the process is about to be killed anyway.
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
