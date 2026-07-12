/// Shared CI-only one-off WorkManager enqueue for the three
/// `m7_worker_*_test.dart` runtime-proof targets
/// (`docs/M7_BACKGROUND_SHARING.md` D6, `docs/E2E_TROUBLESHOOTING.md`).
///
/// ## Why a one-off task, alongside the production periodic task
///
/// Each target's arming code already calls `registerBackgroundCatchup()`,
/// which schedules the production ~15-min PERIODIC WorkManager task. But
/// `tooling/e2e/ci/run-m7-background-catchup.sh` force-runs the worker cold
/// via `adb shell cmd jobscheduler run` AFTER `am kill`, and WorkManager's
/// `ForceStopRunnable` reschedules a force-stopped PERIODIC task to its
/// next ~15-min window instead of running it — the force-run never
/// actually boots the worker, so the lane can never observe a marker. This
/// is fundamental WorkManager behavior, not a defect in the periodic
/// registration.
///
/// A ONE-OFF task, by contrast, is re-enqueued to run ASAP after the same
/// `ForceStopRunnable` reschedule, so the shell's force-run genuinely boots
/// a cold worker process. [registerM7CiOneOffCatchup] enqueues one IN
/// ADDITION to (never instead of) `registerBackgroundCatchup()`, so the
/// periodic-task production path stays exercised exactly as before.
library;

import 'package:haven/src/services/background_catchup_worker.dart'
    show kBackgroundCatchupTaskName;
import 'package:workmanager/workmanager.dart';

/// `uniqueName` of the CI-only one-off catch-up task.
///
/// Deliberately distinct from [kBackgroundCatchupTaskName] (the periodic
/// task's `uniqueName`) so WorkManager treats the two as separate work
/// items — `enqueueUniqueWork` only de-duplicates within the SAME
/// `uniqueName`. `taskName` (passed positionally below) stays the shared
/// production constant so `callbackDispatcher` runs the identical
/// `runBackgroundCatchupTask` gate chain for either task.
const String m7CiOneOffUniqueName = 'm7-ci-catchup-oneshot';

/// Enqueues the CI-only one-off catch-up task the shell script force-runs.
///
/// Call AFTER `registerBackgroundCatchup()` in each `m7_worker_*` target —
/// this is an ADDITION, never a replacement (the periodic registration
/// remains the production-path proof).
///
/// - `taskName` = [kBackgroundCatchupTaskName]: identical to the periodic
///   task's, so the shared `callbackDispatcher` runs the exact same
///   `runBackgroundCatchupTask` gate chain (flag → consent → pending-wipe
///   → FGS-alive → foreground-active → sweep).
/// - `initialDelay` = 60s: keeps the one-off task pending (un-consumed)
///   through the drive's own exit and the shell's `am kill`, instead of
///   letting WorkManager opportunistically run it during the live
///   foreground drive — an early run would both mark the one-off DONE
///   (nothing left for the shell's later force-run to trigger) and could
///   trip the worker's foreground-active gate (D4). Force-run ignores the
///   remaining delay, so 60s only needs to outlast the drive + go-cold
///   window, not the force-run itself.
/// - No `constraints`: the production periodic task requires network +
///   battery-not-low; a constrained job is harder to force-run, so this
///   one-off is deliberately unconstrained (omitting the parameter maps to
///   the native default `Constraints.NONE`).
/// - `existingWorkPolicy: replace`: idempotent across CI retries of the
///   same target.
Future<void> registerM7CiOneOffCatchup() async {
  await Workmanager().registerOneOffTask(
    m7CiOneOffUniqueName,
    kBackgroundCatchupTaskName,
    initialDelay: const Duration(seconds: 60),
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}
