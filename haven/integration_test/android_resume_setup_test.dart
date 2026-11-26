/// Setup drive for the Android resume lane (`e2e-android-resume.yml`,
/// `tooling/e2e/ci/run-android-resume.sh`; owner-directed 2026-11-26, OD-R2).
///
/// Leaves behind exactly the state a user has when their phone dies or Haven
/// updates mid-share: a real (keyring) identity, a circle with an accepted
/// peer whose relay is the CI relay, background sharing on with the CURRENT
/// background disclosure accepted, and the foreground service RUNNING —
/// started from this visible activity, as the app starts it. The host then
/// updates, reboots and kills the app and asserts what resumes.
///
/// The service is started with the lane's CI entry point
/// (`resumeCiBackgroundCallback`), whose only delta from `backgroundCallback`
/// is the debug `ws://` relay opt-in a new process needs. This target never
/// mounts `MapShell`: the foreground stamp is left at the clean-pause `0`, so
/// the resumed service owns publishing from its first cycle.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/providers/locale_provider.dart'
    show resolveAppLocalizations;
import 'package:haven/src/rust/api.dart'
    show
        CircleManagerFfi,
        MemberKeyPackageFfi,
        NostrIdentityManager,
        RelayManagerFfi,
        initKeyringStore;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/circle_creation.dart' show createCircleDelivered;
import 'e2e/_lib/coordination.dart';
import 'e2e/_lib/location_disclosure_seed.dart';
import 'e2e/_lib/resume_ci_fgs.dart' show resumeCiBackgroundCallback;
import 'e2e/_lib/scenario_harness.dart';
import 'e2e/_lib/synthetic_user.dart' show SyntheticUser;
import 'e2e/_lib/test_relay.dart' show defaultStrfryUrl;
import 'e2e/_lib/test_user.dart';
import 'e2e/_lib/throw_time_error_capture.dart';

/// Printed once the service is running; the host waits for it.
const String kResumeSetupArmedMarker = '[ResumeSetup] sharing service armed';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets (not bare test): only a testWidgets body's failure is recorded
  // by the integration binding and can turn `flutter drive` red.
  testWidgets(
    'Android resume setup: sharing on, current disclosure, service running',
    (tester) async {
      installThrowTimeErrorLogging();

      // The REAL platform keyring first, so the resumed process can read
      // Alice's database key from the Keystore.
      try {
        await RustLib.init();
      } on Object {
        // Bridge already up on this engine; a genuine failure surfaces below.
      }
      await initKeyringStore();

      final ctx = await ScenarioHarness.bootstrap();
      final relay = ctx.relay;

      // Alice is the production identity, under the production storage key.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);
      final aliceIdentity = await NostrIdentityManager.newInstance();
      await aliceIdentity.loadFromBytes(secretBytes: aliceSeed);

      final dataDir = await const PathProviderDataDirectory()
          .getDataDirectory();
      final aliceManager = await CircleManagerFfi.newInstance(
        dataDir: dataDir,
        identitySecretBytes: aliceSeed,
      );

      // One accepted peer, so the circle is eligible to publish to.
      final bob = await SyntheticUser.bob(relay);
      await waitForKeyPackage(relay: relay, authorPubkeyHex: bob.pubkeyHex);
      final relayManager = await RelayManagerFfi.newInstance();
      final bobKp = (await relayManager.fetchMemberKeypackage(
        pubkey: bob.pubkeyHex,
        circle: aliceManager,
      )).member;
      if (bobKp == null) {
        throw StateError(
          '[resume-setup] no KeyPackage found on the relay for the peer.',
        );
      }
      final aliceSecret = await aliceIdentity.getSecretBytes();
      try {
        await createCircleDelivered(
          manager: aliceManager,
          relayManager: relayManager,
          identitySecretBytes: aliceSecret,
          members: <MemberKeyPackageFfi>[bobKp],
          name: 'Resume Circle',
          circleType: 'location_sharing',
          relays: <String>[defaultStrfryUrl],
          scenario: 'resume-setup',
        );
      } finally {
        aliceSecret.fillRange(0, aliceSecret.length, 0);
      }
      final bobCircle = await bob.acceptInvitationViaRelay(relay: relay);
      expect(bobCircle.members.length, greaterThanOrEqualTo(2));

      // Sharing on, with the CURRENT background disclosure accepted.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, true);
      await seedLocationDisclosuresAccepted(prefs);
      await BackgroundLocationManager.markForegroundActive(active: false);

      // Started from this visible activity, as the app starts it.
      await BackgroundLocationManager.startService(
        callback: resumeCiBackgroundCallback,
        notificationText: resolveAppLocalizations(null).fgsNotificationSharing,
      );
      expect(
        await BackgroundLocationManager.isRunning,
        isTrue,
        reason:
            'the service must be running before the host updates, '
            'reboots or kills the app',
      );
      debugPrint(kResumeSetupArmedMarker);

      // Drive-process helpers only: Alice's identity, preferences, database
      // and the running service are the state the host goes on to test.
      try {
        await relayManager.shutdown();
        await bob.dispose();
        await relay.dispose();
      } on Object catch (_) {
        // Best-effort; the host replaces this process next.
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
