/// Phase-C1 target for the `e2e-m7-background` runtime-proof lane
/// (`docs/M7E_GO_LIVE_PLAN.md` D6 Phase C1).
///
/// Arms a logged-in, sharing-ENABLED user that ALSO has the M10.1 durable
/// pending-MLS-wipe marker set — the "wake races a logout" scenario. The shell
/// force-runs the worker and asserts it exits at **gate 2** with
/// `kCatchupWorkerPendingWipeMarker` and touches the relay ZERO times: the
/// gate is a SharedPreferences read BEFORE any FFI / keyring / DB / relay code,
/// so a set marker declines the wake cleanly.
///
/// This target deliberately needs neither the real keyring nor a circle: the
/// worker never reaches the bootstrap. It only writes REAL (on-disk)
/// SharedPreferences (the worker's own process reads them) and re-registers
/// the periodic task so the persisted callback handle matches THIS binary after
/// the shell's `install -r`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart' show kBackgroundSharingKey;
import 'package:haven/src/providers/live_sync_provider.dart'
    show backgroundCatchupEnabled;
import 'package:haven/src/services/background_catchup_worker.dart'
    show registerBackgroundCatchup;
import 'package:haven/src/services/pending_mls_wipe_service.dart'
    show kPendingMlsWipeKey;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/m7_worker_ci_oneoff.dart' show registerM7CiOneOffCatchup;
import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets (not bare test): only a testWidgets failure can turn
  // `flutter drive` red. No widget tree is pumped, so `tester` is unused.
  testWidgets(
    'M7 pending-wipe: arm with the M10.1 wipe marker set (gate-2 no-op)',
    (tester) async {
      expect(
        backgroundCatchupEnabled,
        isTrue,
        reason: 'requires backgroundCatchupEnabled=true (M7-E).',
      );

      // Identity present (a logged-in user whose logout is mid-wipe).
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      // Consent stays TRUE so the worker passes gate 1 and REACHES gate 2 —
      // the marker (not consent) is what must decline this wake.
      await prefs.setBool(kBackgroundSharingKey, true);
      // M10.1 durable pending-wipe marker set → gate 2 declines with the no-op
      // marker, before any FFI / keyring / DB / relay activity.
      await prefs.setBool(kPendingMlsWipeKey, true);

      // Re-register so the persisted Dart callback handle matches THIS binary
      // after `install -r` (policy `keep`; production path).
      await registerBackgroundCatchup();

      // ALSO enqueue a CI-only ONE-OFF task (in addition to, never instead
      // of, the periodic task above) — see m7_worker_ci_oneoff.dart. A
      // force-stopped PERIODIC task reschedules to its next ~15-min window
      // instead of running when force-run cold; the ONE-OFF re-enqueues to
      // run ASAP, which is what lets the shell's force-run actually reach
      // this gate-2 no-op.
      await registerM7CiOneOffCatchup();

      expect(prefs.getBool(kBackgroundSharingKey), isTrue);
      expect(prefs.getBool(kPendingMlsWipeKey), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
