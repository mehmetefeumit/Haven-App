/// P0-1 gating experiment — does the Rule-14 MLS guard survive the death of
/// the main Flutter isolate?
///
/// TEMPORARY. Delete this file, `_p0_1ProbeEnabled` /
/// `_probeSessionAvailability` in `background_location_task.dart`, and
/// `tooling/e2e/ci/run-p0-1-session-probe.sh` once the question is answered and
/// recorded in `docs/P0_1_FGS_SESSION_PLAN.md` §2.
///
/// ## The question
///
/// The P0-1 fix plan proposes the foreground service stop opening its own MLS
/// session and instead route work to the main isolate, falling back to opening
/// one itself when no main isolate exists (a cold service start). Two
/// independent reviews argued that fallback can NEVER succeed:
///
///   * `MainActivity` caches no `FlutterEngine`, so Activity destruction tears
///     down the main isolate.
///   * `MapShell.didChangeAppLifecycleState` acts only on `paused`/`resumed`
///     and ignores `detached`; the only `_liveSync?.stop()` lives in
///     `State.dispose()`, which does not run on abrupt teardown.
///   * The guard is released only when the last `Arc<CoreCircleManager>` drops,
///     and one of those `Arc`s lives in a Rust process-global (`static
///     SESSION`, the live-sync engine) that OUTLIVES the isolate.
///
/// If they are right, then after the Activity dies there is nobody to route to
/// AND no way to acquire — the routing design is unbuildable as specified and
/// the architecture must change. This settles it by observation.
///
/// ## What this target arms
///
///   1. A real identity, so the FGS isolate can load one.
///   2. A `CircleManagerFfi` opened by the MAIN isolate and **deliberately
///      never disposed**, held in a top-level reference so GC cannot finalize
///      it. This mimics the production holder: an `Arc` reachable from a Rust
///      global that survives the isolate. When the Activity is destroyed no
///      Dart finalizer runs (the isolate is gone), so the `Arc` — and the
///      guard — persist exactly as `static SESSION`'s would.
///   3. The foreground service, started DIRECTLY rather than through
///      `backgroundServiceLifecycleProvider`. That is deliberate: the provider
///      stops the service on `ProviderScope` disposal, and `flutter_test`
///      unmounts the tree on every passing test — so a provider-started service
///      would be dead before the shell could destroy the Activity. Nothing here
///      depends on the production start path; the experiment is about the
///      guard, not about who started the service.
///
/// The shell (`run-p0-1-session-probe.sh`) then destroys the Activity while the
/// service survives, and reads the probe's verdict from logcat.
///
/// ## Reading the result
///
///   * `[P0-1-PROBE] REFUSED rule14=true` — the guard survived the isolate.
///     The plan's fallback is dead on arrival; the architecture must change.
///   * `[P0-1-PROBE] ACQUIRED` — the guard was released with the isolate. The
///     routing design's cold-start fallback is viable as specified.
///
/// Requires `--dart-define=HAVEN_P0_1_PROBE=true`; without it the probe is
/// compiled out and the lane will report no verdict at all.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/src/constants/location.dart';
import 'package:haven/src/rust/api.dart' show CircleManagerFfi;
import 'package:haven/src/services/background_location_manager.dart';
import 'package:haven/src/services/background_location_task.dart'
    show backgroundCallback;
import 'package:haven/src/services/data_directory_provider.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'e2e/_lib/scenario_harness.dart';
import 'e2e/_lib/test_user.dart';

/// Deliberately leaked. See the class doc: this stands in for the `Arc` held by
/// the Rust `static SESSION`, which outlives the isolate that created it.
/// Storing it top-level keeps the Dart handle strongly reachable so no
/// finalizer can release the guard before the Activity is destroyed.
// ignore: unreachable_from_main
CircleManagerFfi? leakedForProbe;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'P0-1 probe: arm a held MLS session and a surviving foreground service',
    (tester) async {
      final ctx = await ScenarioHarness.bootstrap();

      // Identity under the production key so the FGS isolate reads it back.
      await TestUser.preSeedIdentityAndSkipOnboarding(seed: aliceSeed);

      // The FGS's own gates: consent to run, and both disclosures so the
      // publish path is not blocked for an unrelated reason. (The probe runs
      // before the publish gates, but a blocked publish would clutter the log.)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kBackgroundSharingKey, true);
      await prefs.setBool(kLocationDisclosureAcceptedKey, true);
      await prefs.setBool(kLocationDisclosureBackgroundAcceptedKey, true);

      // Hold the guard from THIS (main) isolate and never release it.
      final dataDir = await const PathProviderDataDirectory()
          .getDataDirectory();
      // `aliceSeed` is the shared sentinel test seed (not a real secret) and is
      // reused by other helpers in this process, so it is passed as-is and NOT
      // zeroed — the same convention as `m7_worker_setup_test.dart`.
      leakedForProbe = await CircleManagerFfi.newInstance(
        dataDir: dataDir,
        identitySecretBytes: aliceSeed,
      );
      expect(
        leakedForProbe,
        isNotNull,
        reason: 'the main isolate must hold the MLS guard before the Activity '
            'is destroyed, or the experiment measures nothing',
      );

      // Start the service directly — see the class doc for why not via the
      // provider.
      await BackgroundLocationManager.startService(
        callback: backgroundCallback,
      );
      expect(
        await BackgroundLocationManager.isRunning,
        isTrue,
        reason: 'the foreground service must be running, or nothing survives '
            'the Activity to run the probe',
      );

      debugPrint(
        '[P0-1-PROBE] ARMED — main isolate holds the MLS guard, foreground '
        'service running. Destroy the Activity now; the next FGS tick reports '
        'the verdict.',
      );

      await ctx.relay.dispose();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
