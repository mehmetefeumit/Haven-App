# E2E / CI Troubleshooting

Practical guide to diagnosing the Haven end-to-end CI lanes. The three e2e
workflows reference this file from their header comments. **Read the "Diagnose
first" rule before concluding any e2e failure is a product regression — an
unhealthy emulator/simulator routinely masquerades as a functional failure.**

## The lanes

| Workflow | What it runs | How | Relay |
|---|---|---|---|
| `e2e-android.yml` | `e2e_combined.dart` (real Alice UI + synthetic Bob/Carol/Dave FFI peers) | `flutter drive` on an AVD | strfry container, `ws://10.0.2.2:7777` |
| `e2e-ios.yml` | `e2e_combined.dart` + `ios_bg_mirror_test.dart` | `flutter test -d <udid>` on a booted simulator | host-native relay, `ws://localhost:7777` |
| `e2e-background-catchup.yml` | M7 background catch-up runtime proof (4 phases + a guest reboot) | `run-m7-background-catchup.sh` under `reactivecircus/android-emulator-runner` | strfry container, `ws://10.0.2.2:7777` |
| `e2e-live-sync.yml` | The SAME two lanes, flag-ON (`HAVEN_LIVE_SYNC=true`) | `workflow_dispatch` only | — |

`e2e-android.yml` / `e2e-ios.yml` take a `live_sync` boolean input (default
**false**). The required PR gate (`ci.yml`) runs them on the **poll path**
(flag-off); the flag-on live path runs on-demand via `e2e-live-sync.yml` until
it is proven green (prove-then-gate — see failure mode 3).

## Diagnose first (the rule)

```bash
gh run view <run_id>                                   # find the failed job
gh run download <run_id> -n e2e-android-<run_id> -D /tmp/x   # or e2e-ios-… / e2e-background-catchup-…
```

Then read the **device/driver** logs before the app logs:

| Lane | Key artifacts |
|---|---|
| Android e2e_combined | `flutter-drive.log` (driver/isolate), `adb-logcat.log` |
| iOS | `flutter-ios-test.log` |
| m7 background | `diag.txt` (**device state!**), `drive.a.log` (setup test result), `logcat.*.log` |

**A functional assertion cannot be trusted if the device was offline/wedged or a
second Flutter engine was present.** Check those two things first.

## Failure mode 1 — `[Sentinel kind: Collected] from resume()` (multi-engine race)

**Symptom** (e2e_android / e2e_ios). In `flutter-drive.log`:

```
VMServiceFlutterDriver: Isolate is paused at start.
VMServiceFlutterDriver: Attempting to resume isolate
Unhandled exception: [Sentinel kind: Collected] from resume()
```

and in logcat: `There is still another flutter engine connected`.

**Root cause.** The M7 foreground-task/background system (`flutter_foreground_task`)
runs its task handler in a **second Flutter engine**. Under `flutter drive`, the
integration-test driver resumes the app's main isolate, but the second engine's
presence causes the target isolate to be collected mid-resume, so the test never
starts. This surfaced when `backgroundCatchupEnabled` went live (M7-E); it is not
a REV-1/M11 defect.

**Fix.** A single-engine compile-time guard in `haven/lib/main.dart`:

```dart
if (!const bool.fromEnvironment('HAVEN_E2E_NO_BACKGROUND')) {
  FlutterForegroundTask.initCommunicationPort();
  BackgroundLocationManager.init();
}
```

`HAVEN_E2E_NO_BACKGROUND=true` is set **only** on the `e2e_combined` builds
(`e2e-android.yml` build `--dart-define`; `e2e-ios.yml` per-step `env` threaded
through `run-ios-sim-scenario.sh`, mirroring the `HAVEN_LIVE_SYNC` "S1" pattern).
It is **never** set on `e2e-background-catchup.yml` (which exists to test that system)
or in production. `e2e_combined` does not exercise the foreground service, so
opting it out is free.

Guard invariant: `scripts/ci/check_m7_native_wake_guards.sh` still pins the FGS
init + reboot receiver present, so the wrapper cannot silently disable them.

**STATUS: confirmed fixed.** `e2e_android` went green with the guard (run
29046445271), and `e2e_ios` cleared the Sentinel too — both now progress past the
driver, which is how the later-step failures below (modes 4 and 5) were exposed.

## Failure mode 2 — "no WorkManager job within 60s" (emulator went offline)

**This message is usually a MISDIAGNOSIS.** It reads as a product regression;
the real cause is almost always an unreachable emulator.

**Confirm** by reading `diag.txt` in the `e2e-background-catchup-<run_id>` artifact:

```
=== adb devices -l ===
emulator-5554          offline ...
=== dumpsys jobscheduler (app slice) ===
adb: device offline
```

If the device is `offline`, the WorkManager job was fine — `discover_job_ids`
was polling a dead transport. Cross-check `drive.a.log`: if the setup test shows
`All tests passed!`, the worker **was** armed.

**Root cause.** Emulator instability. This lane is memory-heavy — a cold worker
isolate boots RustLib + SQLCipher (mlock'd pages) alongside the resident app,
WorkManager, and the FGS, and Phase B reboots the guest. On a software-GPU
GH-hosted emulator, adb can drop its transport to `offline` (the guest is often
still alive — only the socket handshake was lost), or the guest can wedge under
memory pressure (the Phase-A comment already notes `sqlcipher mlock ENOMEM`).

**Fix.** `run-m7-background-catchup.sh` `ensure_device_online` — every discovery
poll first `adb reconnect offline` + `wait-for-device` + confirms
`sys.boot_completed`, bounded by `DEVICE_ONLINE_TIMEOUT` (90 s). A transient
transport drop self-heals; a genuinely-wedged guest now fails with an **accurate
infrastructure reason** instead of a false "WorkManager regression". The workflow
diag step re-handshakes before dumping so future logs distinguish a recoverable
drop from a hard wedge.

**If it recurs as a hard wedge** (device stays `offline` after reconnect): it is
emulator infrastructure, not the product. Re-run the lane; if chronic, raise AVD
RAM or reduce concurrent memory pressure.

## Failure mode 3 — hang / timeout (exit 124) on the flag-on live path

The M11 live-sync path (`HAVEN_LIVE_SYNC=true`) is **not yet validated
end-to-end**. Running the poll-path `FE-1`/`FE-2` scenarios flag-ON can hang past
the inner self-timeout and get killed by the outer step timeout (exit 124).

**Design response — prove-then-gate.** Flag-ON runs only in the on-demand
`e2e-live-sync.yml`; the required PR gate stays on the poll path. The M11 flag-on
scenarios in `e2e_combined.dart` self-skip when `!liveSyncEnabled`. Promote
flag-ON into `ci.yml` (`with: live_sync: true`) only once the on-demand lane is
reliably green.

## Failure mode 4 — WorkManager job never appears while the device is ONLINE

**Symptom.** `M7-LANE-FAIL: no WorkManager JobScheduler job ... within 60s ...
regression` — but `diag.txt` shows the device `online` (mode 2 ruled out) and
`drive.a.log` shows the setup test passed. So the job genuinely is not in
`dumpsys jobscheduler`.

**Root cause — an async-schedule race with `go_cold`.** The Flutter `workmanager`
plugin's `registerPeriodicTask()` returns as soon as WorkManager ENQUEUES to its
Room DB; the actual `SystemJobScheduler.schedule()` runs asynchronously on
WorkManager's executor AFTER the Dart `await` resolves. The old ordering killed
the app (`go_cold`'s `am kill`) right after the drive — so under this lane's
memory pressure the kill could land BEFORE the executor pushed the job to the OS
JobScheduler. The job is then stranded in the Room DB (enqueued in-app, never in
`dumpsys jobscheduler`), and with the process dead no executor remains to push it,
so the poll never sees it. A longer poll cannot help — the app is already gone.

**Fix — confirm the job while the app is ALIVE, before `go_cold`.** `phase_a` and
`run_negative_phase` now poll `discover_job_ids` BEFORE the `am kill`, while the
app process (which `flutter drive` leaves running) can finish scheduling. Only
then `go_cold` — the job is OS-level by then and survives `am kill` (only
force-stop strips jobs), so the cold force-run still exercises a genuinely cold
worker. A job that never appears WHILE THE APP IS ALIVE is now a real registration
failure. (Phase B is unaffected — its poll follows a guest reboot, where
WorkManager's RescheduleReceiver re-schedules from the Room DB; no `am kill` race.)

`ensure_device_online` (mode 2) runs inside this same poll, so a transport drop
and a slow schedule are handled together.

**THE definitive cause — `flutter drive` force-stops the app (run 29072129907).**
The poll fix above and a `-memory` bump were both partial/wrong. The drive log
actually shows WorkManager scheduling the job SUCCESSFULLY —
`D/WM-SystemJobScheduler: Scheduling work ID … Job ID 0` — after which it vanishes
from `dumpsys jobscheduler`. Root cause: `flutter drive` (with
`--use-application-binary`, i.e. NOT `--use-existing-app`) DEFAULTS to STOPPING
the app when the test finishes, and Android's `AndroidDevice.stopApp()` runs
`adb shell am force-stop` (flutter_tools `drive_service.dart` → `android_device.dart`).
`am force-stop` CANCELS the app's JobScheduler jobs — including the one just
scheduled. `go_cold` deliberately uses `am kill` (NOT force-stop) to preserve the
job, but the drive's own teardown force-stopped it FIRST, so it was gone before
discovery. **This is why the lane was never green in CI.** Fix = pass
`--keep-app-running` to the `flutter drive` in `drive_target` (verified in
`flutter drive --help`: *"By default, flutter drive stops the application after
tests are finished"*). Red herrings ruled out: the `sqlcipher_mlock() -1 errno=12`
flood is benign (`RLIMIT_MEMLOCK`, per-process — unaffected by total RAM, which is
why `-memory` did nothing), and `no devices/emulators found` at diag is just the
emulator-runner tearing down on script-fail (host memory is fine in `free -h`).

**Update (run 29074966971) — `--keep-app-running` was NECESSARY but NOT
sufficient.** With it, the drive log shows NO force-stop and WorkManager still
logs a clean schedule (`Job ID 0`, no "Unable to schedule"), yet the job is STILL
absent from `dumpsys jobscheduler` 60 s later — so something beyond flutter
drive's force-stop removes/hides it. `registerBackgroundCatchup` schedules with
constraints (`NetworkType.connected` + `requiresBatteryNotLow`). The cause is not
yet pinned; rather than guess again, `run-m7-background-catchup.sh` now dumps
on-miss diagnostics (`dump_job_diagnostics`: `pidof` the app, `dumpsys package`
stopped-state, `cmd jobscheduler get-job-state PKG 0`, the full jobscheduler
slice, and the WM scheduling lines) and falls back to force-running the
JobScheduler id WorkManager itself logs (`job_ids_from_drive_log`). The worker
success marker still gates a real pass, so the fallback cannot green a phase
falsely.

**DEFINITIVE ROOT CAUSE (run 29100930170, hard `logcat.a.log` evidence).** Two
things were happening: (1) **namespace-blind discovery** — on API 34 WorkManager
schedules into the `androidx.work.systemjobscheduler` NAMESPACE; the plain
`dumpsys jobscheduler | grep` and `get-job-state … 0` (no `-n`) both miss it, but
`cmd jobscheduler run -f -n androidx.work.systemjobscheduler … 0` finds and runs
it (`Running job [FORCED]`). (2) **the real blocker** — when the cold worker
process started, `WM-ForceStopRunnable: Application was force-stopped,
rescheduling` fired, and `WM-WorkerWrapper: Status … is ENQUEUED; not doing any
work and rescheduling for later execution`. WorkManager will NOT run a **periodic**
task's worker when it's force-run early: `ForceStopRunnable` (the app was killed
by `go_cold`) plus periodic-timing make it reschedule to the next 15-min window
instead of executing. **You cannot force-run a periodic WorkManager task's worker
early — it reschedules, never runs.** That is fundamental WorkManager behavior and
is why this lane never passed CI.

**Fix (redesign): trigger the cold worker with a ONE-OFF task.** The m7 test
targets now ALSO enqueue a one-off WorkManager task (same `taskName` →
`callbackDispatcher` handler; distinct unique name; ~60 s initial delay so it does
not run during the foreground drive; no constraints). Unlike a periodic task, a
one-off is re-enqueued to run ASAP after the `ForceStopRunnable` reschedule, so
the shell's force-run actually boots the cold worker. `run-m7-background-catchup.sh`
force-runs the union of the WM-logged Job IDs (periodic + one-off) with `-n
<namespace>`, and `MARKER_TIMEOUT` was raised to 240 s to cover reschedule +
initial-delay + cold boot. Phase B (reboot re-arm) proves the RebootReceiver
wiring + persistence only — a post-reboot periodic force-run has the same
limitation, and the cold worker RUN is proven by Phase A's one-off.

**Refinement (fast negative-phase drives, run 29112158768).** The pending-wipe /
disable drives complete in ~1 s, so WorkManager's async
`SystemJobScheduler.schedule()` logs the Job ID AFTER the drive detaches — it
never reaches `drive.<tag>.log` (the ~7 s setup drive is slow enough to catch it,
the fast ones are not), so discovery came up empty (`no WorkManager Job ID …
within 60s`). Fix: `job_ids_from_logcat` parses the Job ID from the whole-phase
logcat (`start_logcat` runs BEFORE the drive), filtered to the app's live `pidof`
so other apps' WorkManager scheduling cannot leak a foreign id, unioned with the
drive-log + dumpsys sources.

## Failure mode 5 — iOS "could not resolve the data container" (flutter test uninstalls)

**Symptom** (e2e_ios). The `ios_bg_mirror` scenario PASSES
(`✅ ... mirror writes true`), then a later step fails: `ERROR: could not resolve
the data container for com.oblivioustech.haven ... (is the app still installed
after the mirror scenario?)`.

**Root cause.** `flutter test -d <udid>` builds, installs, runs, and then REMOVES
the app on completion (unlike Android's `flutter drive`, which leaves it). Any
SEPARATE step that reads the app's container/plist afterward (the former
`assert-ios-catchup-mirror.sh`) can never find it. This step was added with M7-E
but, because e2e_ios was red on the Sentinel ever since, it never once passed in
CI — it was broken-by-construction for a `flutter test` lane.

**Fix.** The M7-E mirror is asserted at the OS (NSUserDefaults) layer INSIDE
`ios_bg_mirror_test.dart`: it writes to REAL UserDefaults and, after
`prefs.reload()`, reads the value back from the NSUserDefaults DOMAIN the Swift
side consumes (`UserDefaults.standard.bool(forKey:)`). The external post-test
plist step + its script were removed — the in-app read-back is authoritative, and
no external read is possible once `flutter test` removes the app.

**General rule:** never read a `flutter test` app's on-device state from a
separate CI step. Assert it inside the test (which runs in the app's sandbox), or
use `flutter drive` (Android) which leaves the app installed.

## Failure mode 6 — Gradle build fails with HTTP 403 (transient Maven Central)

**Symptom.** `BUILD FAILED` during "Build M7 target APKs" (or any Gradle build),
BEFORE the emulator runs:

```
Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.0.21.
   > Could not GET '.../kotlin-stdlib-2.0.21.pom'. Received status code 403 from server: Forbidden
```

**Root cause.** Transient infrastructure — Maven Central (`repo.maven.apache.org`)
/ `plugins.gradle.org` rate-limit or hiccup on shared GH-runner IPs and return
403/429/5xx during `:classpath` dependency resolution. NOT a code error, NOT
reproducible locally, and it can hit ANY Gradle lane — only the unlucky one fails
a given run (in run 29054586352, e2e_android + every Android build passed; only
e2e_m7 drew the 403). Because it fails at the build step, it can mask/pre-empt the
runtime phases entirely.

**Fix.** `build-integration-apks.sh` wraps each `flutter build apk` in a bounded
retry (`HAVEN_BUILD_MAX_ATTEMPTS`, default 3; `HAVEN_BUILD_RETRY_DELAY_SECS`, 20).
Gradle caches what it already fetched within the job, so a retry only re-fetches
the artifacts the transient failure missed. This hardens the **m7 + integration**
lanes (both invoke the script). A genuine compile error still fails all attempts
and surfaces normally.

**If it recurs on a lane that does NOT use that script** (e2e-android /
android-build / release-build build via Gradle directly): apply the same
bounded-retry pattern to that build invocation — no Android lane caches Gradle
dependencies, so all share this latent flake.

## Failure mode 7 — cold worker panics "android context was not initialized"

**Symptom** (e2e_m7, Phase A). The worker never logs `[CatchupWorker] bootstrap
ok`; the debug-only diagnostic in `background_catchup_worker.dart` shows
`[CatchupWorker] sweep failed detail: PanicException(android context was not
initialized ...)` on the first attempt, then `Keyring lock poisoned: poisoned
lock: another task failed inside` on every retry.

**Root cause — a REAL production bug, not a CI artifact.** The Android keyring
backend (`android_native_keyring_store::Store::from_ndk_context()`, via
`platform_init_keyring()` in `rust_builder/src/api.rs`) reads the Android context
registered by the native call `io.crates.keyring.Keyring.initializeNdkContext()`.
That call lived ONLY in `MainActivity.onCreate()`. A cold WorkManager wake (the
whole point of M7-E: catch up after the app process was killed or the device
rebooted) has NO MainActivity, so the context is never registered →
`ndk_context::android_context()` panics "android context was not initialized" →
that panic poisons the one-shot `KEYRING_INIT` mutex, so every retry then fails
"Keyring lock poisoned". Background catch-up only ever worked when MainActivity
had already run in that live process — i.e. never from a genuinely cold wake.
The same missing-context gap also broke the M7-E `autoRunOnBoot` foreground
service: `RebootReceiver` relaunches the FGS headlessly (no MainActivity), so its
`onStart` → `initKeyringStore()` (`background_location_task.dart`) would hit the
identical panic after a device reboot.

**Fix — register the context in a custom `Application.onCreate()`.**
`HavenApplication` (manifest `android:name=".HavenApplication"`, replacing the
`${applicationName}` placeholder) calls `Keyring.initializeNdkContext(
applicationContext)` once per process, before any Activity/Service/Worker — so a
headless cold worker has it too. The `MainActivity` call was REMOVED, not
duplicated: `ndk_context::initialize_android_context` asserts `previous.is_none()`
and panics on a second call. Mirrors the WhiteNoise reference app's
`WhitenoiseApplication.onCreate`.

**Lesson.** This is exactly the class of bug the runtime lane exists for: unit
tests + static guards mock the keyring and never boot a real headless isolate, so
they were green while the actual cold worker was broken. A green build ≠ a working
cold worker; only booting one proves it.

## Failure mode 8 — cold worker never boots: `… within 240s` timeout after a single force-run

**Symptom** (e2e_m7, most often Phase C2). A phase fails `worker never logged …
within ${MARKER_TIMEOUT}s`, yet the logcat shows the job WAS force-run and even
reached `WM-SystemJobService onStartJob` — immediately followed by `WM-WorkerWrapper:
… is ENQUEUED; not doing any work and rescheduling for later execution` and then
**no** `[CatchupWorker]` line at all. Another phase using the identical mechanism
passes in the same run. Flaky across runs (A/C1 pass, C2 fails, or the reverse) —
the signature of a race, not a product bug.

**Root cause.** The lane force-ran the WorkManager job **once** per phase after
`go_cold`. That single force-run lands in a FRESH app process, and every fresh
process's WorkManager init runs `ForceStopRunnable` (`am kill` + the per-phase
`install -r` leave a `REASON_USER_REQUESTED` exit that WM reads as "force-stopped").
`ForceStopRunnable` **interrupts** the just-started worker (`onStopJob` →
`WorkerWrapper interrupted` → the `ENQUEUED; … rescheduling` line) and re-enqueues
the CI one-off with its ~60s `initialDelay` reapplied — it does **not** run. The
worker then booted only if that fresh process happened to stay alive ~60s so
WorkManager's in-process `DelayedWorkTracker` fired the delayed one-off. That is a
race against the Android app-freezer / LMK: a process resident ~60s (Phase A/C1
survived 60-73s) wins; one frozen or reaped early (a C2 process froze at +16s)
loses, and the worker never boots inside the window.

**Fix — force-run in a RETRY loop until the worker is observed executing**
(`force_run_until_marker`). Round 1's force-run trips `ForceStopRunnable` (which
fires at most once per process init); the process **freezes but stays resident**,
so a second force-run one short round-gap later (`FORCE_RUN_ROUND_POLL`, kept
**shorter than the ~10s freeze window**) is delivered into that **same** initialized
process — `ForceStopRunnable` does not re-fire, `WorkerWrapper` runs the worker, and
`cmd jobscheduler run -f` bypasses the reapplied delay, so it boots. The loop
**stops re-force-running the instant** WorkManager logs it is executing the worker
(`MARK_WORKER_STARTED = "WM-WorkerWrapper: Starting work for
dev.fluttercommunity.workmanager.BackgroundWorker"`) and then waits uninterrupted
for the marker — so the short gap never restarts Phase A's slow (~10-30s) cold
bootstrap (`run -f` on an already-running job is image-dependent; never assume it
is a no-op). Each round logs the app pid; a timeout with a churning pid points at
the emulator LMK-reaping the mlock-heavy process (an infra limit of proving a cold
WM worker), not a product regression.

**Lesson.** You cannot reliably force-run a WorkManager worker in the FIRST process
after a force-stop — `ForceStopRunnable` eats that run. Re-issue the force-run into
the now-initialized (resident, thawed) process, and gate on the worker *starting*
(not just its final marker) so you know exactly when to stop hammering.

## What these lanes do NOT cover

The iOS simulator keeps the app alive and the VM-service attached, so it does
**not** reproduce real-device background **suspension**. A "background execution
stops" bug will not surface here — that class needs a physical device, which is
out of scope for GitHub-hosted runners.

## Feature flags seen in these lanes

| Flag | Meaning | Default |
|---|---|---|
| `HAVEN_LIVE_SYNC` | M11 persistent live-sync engine (vs the retained poller) | `false` |
| `HAVEN_E2E_NO_BACKGROUND` | skip M7 FGS/background init (single-engine for `flutter drive`) | `false` (prod), `true` on e2e_combined only |
| `backgroundCatchupEnabled` | M7-E background catch-up (Dart const) | `true` (LIVE) |
| `enablePeriodicSelfUpdate` | M5 hourly self-update | `false` |

## Pointers

- Migration state: memory `project_wn_relay_epoch_migration_plan`,
  `docs/M11_ROLLOUT.md`, `docs/M7_BACKGROUND_SHARING.md`.
- REV-1 (distributed SelfRemove fork): `docs/M11_ROLLOUT.md`.
- The `check_m7_native_wake_guards.sh` guard pins the M7-E released state
  (including `HAVEN_LIVE_SYNC` `defaultValue: false`); the Phase-B flip must
  update guard check 14b in lockstep.
