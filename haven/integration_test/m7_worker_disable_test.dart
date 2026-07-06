/// Phase-C2 target for the `e2e-m7-background` runtime-proof lane
/// (`docs/M7E_GO_LIVE_PLAN.md` D6 Phase C2).
///
/// Arms the "leaked wake survives opt-out" scenario: an identity is present and
/// a WorkManager task is REGISTERED, but background sharing is DISABLED. The
/// shell force-runs the worker and asserts it exits at **gate 1** with
/// `kCatchupWorkerConsentDisabledMarker` and touches the relay ZERO times: the
/// consent gate is a SharedPreferences read BEFORE any FFI / keyring / DB /
/// relay code, so a disabled flag declines the wake cleanly.
///
/// Consent is set to `false` DIRECTLY via SharedPreferences — deliberately NOT
/// via `disableBackgroundScheduling()`, which would cancel the job. The whole
/// point is that an OS-queued wake registered while sharing was on still
/// no-ops after the user opts out. The task is registered FIRST, then consent
/// is cleared, so a real queued job exists for the shell to force-run.
///
/// Needs neither the real keyring nor a circle: the worker never reaches the
/// bootstrap.
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

import 'e2e/_lib/test_user.dart' show TestUser, aliceSeed;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // testWidgets (not bare test): only a testWidgets failure can turn
  // `flutter drive` red. No widget tree is pumped, so `tester` is unused.
  testWidgets(
    'M7 disable: register a task then disable consent directly (gate-1 no-op)',
    (tester) async {
      expect(
        backgroundCatchupEnabled,
        isTrue,
        reason: 'requires backgroundCatchupEnabled=true (M7-E).',
      );

      // Identity present (a user who previously had sharing on).
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      final prefs = await SharedPreferences.getInstance();
      // Clear any stale wipe marker so the wake would be declined ONLY by the
      // consent gate (isolates gate 1 as the exit path under test).
      await prefs.setBool(kPendingMlsWipeKey, false);

      // Register the periodic task FIRST (mirrors a user who had sharing on;
      // also refreshes the callback handle for THIS binary after `install -r`).
      await registerBackgroundCatchup();

      // Now opt out DIRECTLY — NOT via disableBackgroundScheduling(), which
      // would cancel the job. The registered task survives; the worker must
      // no-op at gate 1 on wake.
      await prefs.setBool(kBackgroundSharingKey, false);

      expect(prefs.getBool(kBackgroundSharingKey), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
