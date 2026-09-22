# E2E / CI Troubleshooting

Practical guide to diagnosing the Haven end-to-end CI lanes. The three e2e
workflows reference this file from their header comments. **Read the "Diagnose
first" rule before concluding any e2e failure is a product regression — an
unhealthy emulator/simulator routinely masquerades as a functional failure.**

## The lanes

These are the lanes this guide has failure modes for — the core-flow pair, the
two that share their harness, and the integration lane. They are **not** the
full E2E fleet: the scenario lanes (`e2e-ios-background-publish`,
`e2e-fgs-publish`, `e2e-profile`, `e2e-relay-customization`, `e2e-clock-skew`,
`e2e-kp-rotation`, `e2e-network-reconnect`, the real-GPS and auth-tier lanes)
are inventoried in CLAUDE.md's "CI Pipeline" section and each carries its own
header. A symptom below is worth reading against any of them; a lane-specific
oracle is not. One thing is uniform across the whole fleet, these lanes and
the scenario lanes alike: every captured log goes through `scan-logs.sh` — the
key-material floor plus the `haven-logscan` identifier scanner — before it is
echoed or uploaded (failure mode 13; `check_logscan_wired_everywhere.sh` is
what keeps that true).

| Workflow | What it runs | How | Relay |
|---|---|---|---|
| `e2e-android.yml` | `e2e_combined.dart` (real Alice UI + synthetic Bob/Carol/Dave FFI peers); every captured log is run through `scan-logs.sh` — the key-material floor plus the `haven-logscan` identifier scanner — before it is echoed or uploaded (failure mode 13) | `flutter drive` on an AVD, behind the recording wire proxy | strfry container behind the proxy, `ws://10.0.2.2:7788` → `ws://127.0.0.1:7777` |
| `e2e-ios.yml` | `e2e_combined.dart` + `ios_bg_mirror_test.dart`; every captured log — the transcript, both unified-log exports, the relay, proxy and summary logs — runs through `scan-logs.sh` against the manifest sealed from the proxy's declarations plus the host needles (failure mode 13) | `flutter test -d <udid>` on a booted simulator, behind the recording wire proxy | host-native relay behind the proxy, `ws://127.0.0.1:7788` → `ws://localhost:7777` |
| `e2e-background-catchup.yml` | M7 background catch-up runtime proof (4 phases + a guest reboot); each drive log is gated through `scan-logs.sh` (host needles) before it is echoed, and the whole log directory before upload (failure mode 13) | `run-m7-background-catchup.sh` under `reactivecircus/android-emulator-runner` | strfry container, `ws://10.0.2.2:7777` |
| `e2e-live-sync.yml` | The SAME two lanes, flag-ON (`HAVEN_LIVE_SYNC=true`) — a manual re-run of what `ci.yml` already gates on | `workflow_dispatch` only | — |
| `soak-core.yml` | the Tier-1 soak rig (`tooling/soak`): several whole Haven devices in one process against hermetic relays broken on a seeded schedule, grading haven-core's invariants; no app, no emulator. Every capture is scanned twice before the upload — against the manifest the rig sealed from its own declarations and against the host needles (failure mode 14) | `run-soak-core.sh` under `run-with-deadline.sh`, on a plain ubuntu runner | in-process `nostr-relay-builder` relays, ws:// loopback |
| `e2e-integration.yml` | seven component targets (`smoke_test`, `app_test`, `keyring_test`, …), one after another; the lane's one manifest is sealed from the host needles before the first target, and every target's captures and the aggregate go through `scan-logs.sh` (failure mode 13) | `run-integration-tests.sh` → `run-single-avd-scenario.sh` per target, on one AVD | strfry container reset per target, `ws://10.0.2.2:7777` |

`e2e-android.yml` / `e2e-ios.yml` take a `live_sync` boolean input (default
**false**) and always pass `--dart-define=HAVEN_LIVE_SYNC=<input>`, so a lane
forces its receive path rather than inheriting the compiled-in default.

`ci.yml` runs **both paths on every commit**: `e2e-android` / `e2e-ios` on the
poll path (flag-off) and `e2e-android-live-sync` / `e2e-ios-live-sync` on the
live path (flag-on). All four gate. `e2e-live-sync.yml` is retained only as a
convenience for re-running the flag-on pair on a branch without the full fleet;
it calls the same reusable lanes, so it cannot drift from the gate.

Note which way round the two paths sit today: `liveSyncEnabled` defaults to
**true** (M11 Phase B), so the LIVE path is what production ships. The flag-off
lane is not the default path — it keeps the retained poller, the documented
rollback path, proven for as long as it stays in the tree.

## Diagnose first (the rule)

```bash
gh run view <run_id>                                   # find the failed job
gh run download <run_id> -n e2e-android-<run_id> -D /tmp/x   # or e2e-ios-… / e2e-background-catchup-…
```

Then read the **device/driver** logs before the app logs:

| Lane | Key artifacts |
|---|---|
| Android e2e_combined | `flutter-drive.log` (driver/isolate), `adb-logcat.log` |
| iOS | `flutter-ios-test.log`; `sim-unified.log` (Haven's own unified-log lines: `subsystem == "frb_user" OR process == "Runner"`); `sim-unified-full.log` (the whole device, last 64 MiB — see failure mode 12 for why there is no `sim.logarchive`) |
| m7 background | `diag.log` (**device state!**), `drive.a.log` (setup test result), `logcat.*.log` |

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

**Confirm** by reading `diag.log` in the `e2e-background-catchup-<run_id>` artifact:

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

**Symptom.** A flag-on lane (`HAVEN_LIVE_SYNC=true`) hangs past the inner
self-timeout and is killed by the outer step timeout (exit 124).

**Status — prove-then-gate is DONE.** This is the failure that rollout existed
to contain, and the flag-on lanes have since been promoted into `ci.yml`, where
they gate every commit beside the poll-path lanes. A 124 here is a regression to
diagnose, not an expected property of an unproven path.

It is also not an under-budgeting artefact. Every timeout in both lanes is
already a `inputs.live_sync && <flag-on> || <flag-off>` ternary — job, step,
outer deadline and inner drive timeout all widen on the flag-on path, because
the live-sync scenarios run on top of the core flow. (The two platforms pick
different values; read them off the lane rather than assuming Android's.) So a
124 means the live path genuinely stopped making progress — work it like any
other lane, starting from "Diagnose first" above.

One asymmetry to keep in mind while reading logs: the M11 scenarios in
`e2e_combined.dart` self-skip when `!liveSyncEnabled`, so a poll-path lane that
is silent where you expected live-sync coverage has skipped, not passed.

## Failure mode 4 — WorkManager job never appears while the device is ONLINE

**Symptom.** `M7-LANE-FAIL: no WorkManager JobScheduler job ... within 60s ...
regression` — but `diag.log` shows the device `online` (mode 2 ruled out) and
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

## Failure mode 6 — Gradle build fails resolving dependencies (transient 403/429)

**Symptom.** `BUILD FAILED` during any Gradle build step, BEFORE the emulator
runs:

```
Could not resolve org.jetbrains.kotlin:kotlin-stdlib:2.0.21.
   > Could not GET '.../kotlin-stdlib-2.0.21.pom'. Received status code 403 from server: Forbidden
```

**Root cause.** Transient infrastructure — Maven Central (`repo.maven.apache.org`)
/ `plugins.gradle.org` rate-limit or hiccup on shared GH-runner IPs and return
403/429/5xx during dependency resolution. NOT a code error, NOT reproducible
locally, and it can hit ANY Gradle lane — only the unlucky one fails a given run
(in run 29054586352, e2e_android + every Android build passed; only e2e_m7 drew
the 403; in run 35622556197 one lane drew HTTP 429 six times over 2m47s while
twelve siblings built the same commit clean). Because it fails at the build
step, it can mask/pre-empt the runtime phases entirely.

**The fix is the CACHE; the retry is the backstop.** A cold `~/.gradle` makes a
lane fetch hundreds of POMs before it compiles anything, and every one of them
is a chance to be rate-limited. MEASURED across 182 samples in 22 green runs: a
cold `assembleDebug` takes 455-946 s, a warm one 29-48 s. The warm build does
not make the requests, so it cannot draw the limit.

Every Gradle-building job therefore restores a shared, read-only dependency
cache (`~/.gradle/caches/modules-2` + `~/.gradle/wrapper`) on one canonical key
before its first build — 13 restore steps today. Exactly ONE job writes that key,
`build-check.yml`'s `android`, from a successful build only, under the restore
step's own `cache-primary-key` output; a lane that wipes `~/.gradle` for disk
headroom (e2e-relay-customization) must never be able to publish the hole. Every
restore is `continue-on-error: true` under a `timeout-minutes`, because an
optimisation must never redden a lane that would have built cold.

Two jobs are exempt, each with its reason on the line above its `runs-on`:
`release-build.yml`'s `android`, because it signs and ships the artifact and
nothing would authenticate the dependencies a restored cache put on disk (no
`verification-metadata.xml`; the Gradle distribution itself is pinned by
`distributionSha256Sum`), and
`e2e-flakiness-stress.yml`'s `flake_stress`, whose job cap is already GitHub's
360-minute ceiling with 0.8 min of headroom, less than a restore step's cap.
`scripts/ci/check_gradle_build_hardened.sh` enforces all of this (C1-C6).

**The retry.** Every Gradle build a workflow invokes DIRECTLY — the E2E lanes'
and `build-check.yml`'s — goes through `scripts/ci/build_apk_with_retry.sh`; a
bare `flutter build apk` in a workflow is a C3 violation. (The exception is
`release-build.yml`, which calls `scripts/build_release.sh`, and that script
runs `flutter build` itself; a transient on a tag is a human re-run, not an
in-job recovery. Its only retry is the widened in-Gradle window from
`haven/android/gradle.properties`, which every Gradle build here gets.) The
wrapper makes up to 4 attempts
with a fixed 20/45/75 s ladder (`HAVEN_BUILD_MAX_ATTEMPTS`,
`HAVEN_BUILD_RETRY_BUDGET_SECS`), inside a 180 s wall-clock budget shared by the
WHOLE step — so a seven-APK step cannot spend it seven times over — and it
refuses to start an attempt whose projected cost will not fit. It CLASSIFIES:
only a dependency-resolution signature is retried, a disk/OOM signature is
never retried (that would turn a capacity problem into a green build), and
anything unclassified fails immediately with the build's own exit code.

Note what it cannot decide. `Could not resolve all files for configuration ...`
is what Gradle prints both for a transient and for a dependency version this
commit got wrong, so the retry class covers both. The verdict annotation is
where that is told honestly, and it has **three wordings** — read which one you
got before re-running:

| The output carried | The annotation says | What to do |
|---|---|---|
| `status code 429` | a repository rate-limited this runner; INFRASTRUCTURE, not a product failure | re-run on a different runner; a recurrence means the cache is not being restored |
| `Could not find …` + `Searched in the following locations` | Gradle could not find a coordinate in any repository, and that is also what a wrong version prints | read the Gradle error FIRST — if this commit changed a dependency, no re-run will fix it |
| neither | no HTTP status was reported, so the cause is not knowable from here | usually infrastructure, but check the diff for a dependency change |

The original Gradle output is always printed above the annotation, unaltered;
the annotation never reprints the coordinate itself.

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

## Failure mode 9 — leave never converges: "converging on Alice's handoff burst" times out

**Symptom.** A leave scenario (admin handoff or non-admin) runs cleanly — the
leave publishes, `[Leave] completed`, the leaver's own circle list empties — but
a remaining peer never drops the leaver. The drain log repeats
`groupUpdates=0 … publishedCommits=0` round after round until the 60s
convergence budget expires. No error is raised anywhere.

**Cause.** A bare `SelfRemove` is a PROPOSAL (RFC 9420 §12.1.2). It becomes a
removal only when a remaining member publishes the commit their engine stages
for it. The engine hands that commit back as
`DecryptLocationOutcomeFfi.autoCommits` — it cannot publish it itself, because
the Rust `CircleManagerFfi` holds no relay handle. Two Dart ingest APIs exist and
only one is safe on a receive path:

| API | Receive-side auto-commit |
|---|---|
| `decryptLocationCollectingCommits` | **surfaced** for the caller to publish, then confirm on a ≥1-relay ack |
| `decryptLocation` | **rolled back** (`publish_failed`) |

Ingesting a peer's `SelfRemove` through the shim discards the eviction on
arrival. The proposal is consumed, nothing is published, and the leaver stays in
the roster permanently — silently, which is why the only symptom is a timeout far
downstream. This bit the E2E synthetic peer: its drain used the shim, so every
leave scenario deadlocked.

**Fix / check.** The receiving side must run the full dance: publish once,
`confirmPublished` on an ack, `publishFailed` otherwise — never confirm before an
ack, never drop the pending ref. Production does this in
`LocationSharingService._publishAutoCommits` (foreground poll); live-sync and
background catch-up publish it in-Rust via
`haven_core::relay::auto_commit::resolve_receive_publish_work`. The E2E synthetic
peer mirrors it in `SyntheticUser._publishAutoCommits`.

Two guards keep this from recurring without an emulator lane:
`haven/test/lints/receive_side_auto_commit_test.dart` (scans for the shim CALL —
a substring search for the safe name is not enough, the file also documents it)
and `haven-core/tests/circle_integration_test.rs`
`peer_self_remove_surfaces_a_receive_side_auto_commit` (pins both APIs on the
same proposal).

**Expected side effect, not a bug.** Once the contract is honoured, EVERY
remaining member auto-commits the proposal — a real concurrent-commit fork, just
as in production when someone leaves a 3+-person circle. The engine resolves it
(deterministic `CommitOrderingKey` branch selection; the loser rolls back and
adopts the winner), but resolution needs all peers to keep ingesting after the
loser's commit lands. Poll to the convergence predicate itself, re-snapshotting
the shared inbox each round; polling each peer to its own state and then
sampling once can observe a mid-convergence instant and fail spuriously.

**What that predicate must NOT be: "leaver gone from both + equal epochs".** A
fork satisfies both terms. Both branches remove the leaver, and both advance by
exactly one epoch, so the two peers sit on epoch N+1 with identical member
sets and *different group states*. Equal epochs implied one branch only under
the pre-migration single-committer election, where a single SelfRemove commit
ever existed; DM-4b deleted that election and invalidated the reasoning without
touching the code that relied on it.

The discriminating predicate is a **current-epoch cross-decrypt**: have one peer
publish a location minted at its current epoch and require the other to decrypt
*those exact coordinates* in the same round. Two branches derive different epoch
secrets, hence different `marmot/group-event` exporter secrets, so a successful
decrypt means the reader holds the publisher's current-epoch secret — one shared
branch. Match on the coordinates, never on "a decrypt succeeded": the engine's
epoch lookback (5 past epochs) happily decrypts a location minted at a SHARED
PAST epoch on either branch. `_reconcileHandoff` in `e2e_combined.dart`
implements this, and `scripts/ci/check_e2e_handoff_convergence_oracle.sh` pins
it.

## Failure mode 9b — Phase 5 passes, then Phase 6 times out on the non-admin leave

**Symptom.** The handoff phase reports `handoff converged … epoch=5 on both
peers` and Phase 5's epoch-delta assertions pass, but the next phase hangs:
`post-leave drain groupUpdates=0 members=2 stillHasLeaver=true`, repeated until
the 60s budget expires. Every drain re-processes the same event set, and the
leaver's `SelfRemove` shows `0 result(s), 0 auto-commit(s)` while burning real
crypto time each round (the convergence re-tick loop).

**Cause.** Phase 5 let a fork through — see the predicate discussion above. The
leaver then mints its `SelfRemove` on its own orphan branch, which the remaining
peer's engine cannot apply at any epoch, so no eviction commit is ever staged.
The giveaway in logcat is two `published + confirmed receive-side auto-commit`
lines with *different* event ids (one per remaining peer), followed by a
`Wrong Epoch: message.epoch() N != N+1` when each peer meets the other's commit.

CI run 32688074045 is the worked example. The fork was routine and would have
resolved on the next drain, but the only step that performed that drain was a
`try`/`catch`-swallowed "non-gating" location probe; its publish was lost when
the harness relay socket dropped (strfry `[1] Disconnect`, proxy
`c0 c2r: read failed`), the exception was ignored by design, and the fork
survived into Phase 6.

**Fix / check.** Two rules, both now enforced. The convergence gate must include
the cross-decrypt term (guard above). And any step a convergence gate depends on
must be *inside* the poll and feed the predicate — a probe whose failure is
logged and ignored is load-bearing exactly when it silently stops running.
Transport loss is then a retried round with a fresh event id, not a false pass.

## Failure mode 10 — the job dies with "the hosted runner lost communication with the server"

Not a Haven failure, and there is nothing in this tree to fix. GitHub reports it
as a job-level ANNOTATION rather than a step failure; the job's steps stay
`in_progress`/`pending` forever and the whole log blob is usually absent from
the API (`BlobNotFound`), because the agent that would have uploaded it is what
died.

**How to tell it apart from a real red**, in order:

1. `gh api repos/<owner>/<repo>/actions/jobs/<id> --jq '.steps[] | select(.conclusion==null) | .name'`
   — a genuine failure has exactly one non-null `conclusion: failure`; this has a
   step stuck `in_progress` and every later step `pending`.
2. The job outlives its own step `timeout-minutes` without being killed. The step
   deadline is enforced BY the runner agent, so an agent that is gone cannot
   enforce it. In run 32622119290 the `e2e_location_provider_toggle` build step
   started at 06:16:42 under a 30-minute cap and the job was only declared failed
   at 07:00:54 — 44 minutes later. That overshoot is the signature.
3. No artifact was uploaded, including the `if: always()` diagnostics.

**Do not read it as a lane defect, and do not tune the lane for it.** In run
32622119290 the lane that died builds ONE APK; `e2e_integration`, which builds
SEVEN through the same `build-integration-apks.sh` on the same runner image,
passed in the same run — so the build profile is not the differentiator. Re-run
the lane. If it recurs on the same lane across runs, the resource peak is the
first thing to measure (see failure mode 2's `free -h` / `df -h` diagnostics and
the build-before-boot discipline every Android lane already follows).

## Failure mode 11 — rc=124 after `All tests passed!`: MainActivity relaunched under the driver

**Symptom** (as seen through `run-single-avd-scenario.sh`; a lane with its own
orchestrator hangs the same way, to its own drive timeout). A target is
killed at its per-target cap (`exceeded 10m and was killed (rc=124)`) although
its drive log contains `All tests passed!`. Read the PIDs, not just the lines:

- the drive log carries **two** `00:00 +0: (setUpAll)` lines from the **same**
  pid, with `Detaching Geolocator from activity` and a
  `FlutterActivityAndFragmentDelegate` line between them (the first engine's
  own delegate line is printed before the drive starts reading the device log);
- the target's logcat has `W System: ClassLoader referenced unknown path:` in
  the app pid, then `WindowManager: finishDrawing of relaunch: … MainActivity`.

Anything the app logs after that `All tests passed!` — in run 34511084722 a
burst of `StateError`s from MapShell's startup reading the test's disposed
`ProviderScope` — is the orphaned second engine outliving its suite; a healthy
drive force-stops the app a fraction of a second after that line. It is a
consequence of the hang, not its cause. Unlike failure mode 1, the second
engine here is not the foreground service's: it is the relaunched activity's
replacement for the first. Its pre-connect form is the `[Sentinel kind:
Collected]` from `GetHealth` that `is_connect_flake` retries; run 29218745757
shows the same relaunch signature, though its surviving logs cannot show the
trigger (and it also carries failure mode 1's `There is still another flutter
engine connected`).

**Root cause.** Android relaunched MainActivity mid-drive. A FRESH install's
`PACKAGE_ADDED` makes OverlayManagerService recompute the new package's overlay
paths (always, for a newly added package) and — because they change on a fresh
install, from none to the framework overlays — call
`scheduleApplicationInfoChanged`, which bumps the asset sequence of the
package's visible activities: a configuration change no `android:configChanges`
can absorb, so the activity is relaunched. `FlutterActivity` destroys its
engine with it, taking the isolate `flutter drive` is attached to; the new
activity boots a second engine that runs the whole suite again from `main()`
(the driver's connect had already turned off pause-on-start for the whole VM).
Its results go nowhere, and the driver's pending `requestData` is never
answered — the host only logs a warning when its timeout passes, so the
harness cap is what ends it.

It is a race against the broadcast queue, which a freshly booted emulator backs
up behind post-boot churn. In run 34511084722 (`app_test`, the second target)
system_server's receivers got the Phase-2 install's `PACKAGE_ADDED` 13.6 s after
the install — 0.5 s after MainActivity was first displayed. In the green run
34488512808 the same broadcast landed 2.8 s after the install, 0.4 s before
`am start`. The commit between those two runs touched neither the app nor the
test.

**Fix.** Every Android lane installs the app through one library,
`tooling/e2e/ci/app-install-lib.sh`: `install_fresh` clears any prior install
first, `install_app` installs over whatever is there, and after any install
that was FRESH — the package absent beforehand — both check it landed and then
block on one round trip that runs four `;`-separated commands on the guest:

```
cmd package wait-for-handler --timeout 120000 ; h=$?
am wait-for-broadcast-barrier --flush-broadcast-loopers ; b=$?
cmd package haven-not-a-command ; c=$?      # control
am         haven-not-a-command ; a=$?       # control
echo "haven-barrier-rc $h $b $c $a"
```

`;` and not `&&`, so a half that fails still reports its own code instead of
vanishing into a short circuit, and the host branches only on that
guest-printed verdict line — never on a number adb reports or a word the
framework prints. PackageManagerService posts the `PACKAGE_ADDED` send to its
own handler and only then answers the installer (`android-14.0.0_r1`,
`InstallPackageHelper.handlePackagePostInstall`), so a bare barrier taken as
`adb install` returns can pass before the broadcast is enqueued. Draining that
handler is what closes the gap: the loopers flag alone covers it only once it
has sent some broadcast before (`BroadcastLoopers` registers loopers lazily),
which on a freshly booted guest it may not have. Both commands are in that
release's source. `flutter drive`'s own reinstall (it always reinstalls) is a
REPLACE, as is any install over an installed package, and the overlay manager
ignores a replace for a package that neither declares nor is targeted by an
overlay. So a replace takes no barrier, and a sound lane never reds on a wait
that could not have mattered. What the barrier cannot reach are the in-process
hops after hand-over (FgThread, the overlay manager's thread, FgThread again) —
a margin of everything before the drive's launch, not a barrier.

**The two controls refuse a guest that answers 0 — and were measured before
they did.** An rc of 0 from a command that does not exist reads exactly like an
rc of 0 from one that ran, so a guest that answered 0 to everything is the
single shape that would make the whole barrier a no-op nobody could see. The
expected answer comes from source — both `cmd package` and `am` fall through to
`BasicShellCommandHandler.handleDefaultCommands`, which prints `Unknown
command: <cmd>` and returns -1, which `cmd.cpp` hands back as exit status 255 —
and was confirmed on the runner before it became a refusal: all twelve Android
lanes of CI run 35664400984 (api-34 `google_apis` x86_64) printed `install
broadcasts flushed (handler/barrier rc 0/0, unknown-command control rc
255/255)`. Until then the control only warned, because a refusal resting on an
unmeasured probe is what cost run 35536892150 thirteen Android lanes. The
success line still records all four codes on every fresh install, so a future
image that answers differently is diagnosable from the log.

**Fail-closed outcomes**, each named rather than driven into the race: a failed
install; a queue that has not drained within `INSTALL_BARRIER_SECS` (120 s, a
library constant no lane can tighten — rc 124); a verdict line that is absent,
truncated or unparseable, i.e. the guest exited 0 without saying what the
barrier's own commands returned; a non-zero `h` or `b`, which is what a guest
predating either command reports; and **rc 125-127, which is this runner
failing to execute the command at all** rather than any device fault — the
chain ends in an `echo`, so no guest-side failure can reach adb's own exit
status. That last one is what `timeout … adb` returned in eight of run
35536892150's thirteen Android lane jobs, with adb off the PATH, and it says
so: *"nothing was asked of `<device>` … That is this runner's tooling."*

Where each lane installs: `run-single-avd-scenario.sh` Phase 2 (and through it
e2e-android, e2e-profile, e2e-integration, e2e-relay-customization and
e2e-flakiness-stress); Phase 1 of `run-b1-fgs-publish.sh`,
`run-b3-real-gps.sh`, `run-b5-permission-revocation.sh`,
`run-b6-location-provider-toggle.sh`, `run-b8-clock-skew.sh`,
`run-b9-network-reconnect.sh` and `run-kp-rotation.sh`; B5's Phase 6 restore,
which is fresh because ACT 1's drive teardown uninstalled the package; and M7's
Phase A (its C1 and C2 install over Phase A's package — replaces, no barrier).
The runner's connect-flake retry restores the app the same way: a failed
attempt's `flutter drive` teardown stops and uninstalls it
(`drive_service.dart` `stop()`), so the next attempt's own install would be a
fresh, unflushed one, and the Phase-3 grants would be gone with the package.
B1 keeps its own Phase-4 barrier as well: that one runs after launch, for the
drive's force-stop and replace broadcasts that reset LocationManagerService's
registrations, and neither barrier covers the other's broadcast.

Two repo-guards steps keep it that way. `app-install-lib.sh --self-test` runs
80 fixtures (the count is pinned by equality) against a stub device: the order,
the handler drain and the loopers flag, the bound, the check that a fresh
install landed, the verdict line and every way it can be missing or wrong, the
two unknown-command controls including the guest that answers 0 to everything,
each fail-closed path, and the no-barrier-on-a-replace rule. Its first suite
runs the stub `timeout` and coreutils' real one side by side on the same
inputs, because `install_app` reads 124 (a queue that never drained), the
command's own rc, and 125-127 (this runner) as three different verdicts that a
fake could silently flatten into one. `app-install-lib.sh --check-installs`
fails if any lane installs the app another way, redefines those functions, or
talks to adb and launches the app with `flutter drive`, `flutter test` or
`flutter run` without also installing through them — so a new lane written the
ordinary way cannot miss the barrier.

**Not covered.**

- The pin is lexical, and says what it cannot see: an install behind `eval`,
  `bash -c` or a variable, a path, or a function standing in for `adb`; one
  inside `$( … )` in an unquoted heredoc body, or in a heredoc fed to `bash`
  or `adb shell`; a device-side `pm install` quoted into one `adb shell "…"`
  argument; and a few constructs its lexer misreads (listed in the library).
  R3 checks that the install call is present, not that it runs first.
- If `flutter drive`'s reinstall FAILS, flutter_tools falls back to uninstall
  plus a fresh install — unflushed.
- A post-boot change to a framework overlay relaunches every visible activity
  and is not a broadcast at all. Run 34511084722 switched the navigation-mode
  overlay at 18:23:44 and relaunched the launcher, 23 s before its first target
  launched; a faster first target would have been exposed.

## Failure mode 12 — red on `secret-leak guard tripped`, and the artifact has no drive log

**Symptom:** the drive step ends with `LEAK: /tmp/flutter-drive.log [<label>] at
line(s): N` (or the same for `adb-logcat.log`, `flutter-ios-test.log`,
`sim-unified*.log`, a relay/blossom log or `diag.log`) followed by
`ERROR: secret-leak guard tripped`. The failure artifact is missing exactly those
files, and the job log does not carry the drive log either.

**That is the guard working, not a broken upload.** `scan-logs-for-secrets.sh`
(CLAUDE.md Security Rules 6 and 15) returns rc 1 on a leak, and the gate around
it — `scan_logs_or_contain` in `run-single-avd-scenario.sh`,
`scan_log_or_contain` in `run-ios-sim-scenario.sh`, `bgp_scan_or_contain` in
`run-ios-bg-publish.sh`, `logscan_gate_dir` over the whole log directory in the
four directory-scanning runners (`run-integration-tests.sh`,
`run-relay-customization.sh`, `run-flake-stress.sh`,
`run-m7-background-catchup.sh`) and in the scenario runners' EXIT traps — every
one of them a call into `tooling/e2e/ci/logscan-gate.sh` — and the `Scan
captured logs for secrets before upload` step in every workflow — **deletes
every file it scanned before exiting non-zero**. The `if: failure()` upload that
the red run triggers then finds nothing to publish (`if-no-files-found:
ignore`), and every runner echoes a drive log into the job log only *after*
its gate has passed (each runner's `--self-test` pins that order, and
`check_logscan_wired_everywhere.sh` pins the workflows'). Artifacts and job
logs on this repository are public for 14 days; a guard that failed the lane
and then published the line it failed on would not be a guard.

rc 3 is a different verdict: the log was absent or empty (the lane died before
writing it), the files are kept, the step still fails, and the message says
`UNUSABLE`, not `LEAK`. The scanner's header states the taxonomy.

**What to do:** the LEAK line names the file, the pattern label and the line
number — never the content. Reproduce locally against your own emulator or
simulator (the same runner script, the same scenario) and read the flagged line
on your machine; then fix the log site (Rule 15 forbids the value, whatever the
level). Do not re-run: the patterns are deterministic and both retry gates
classify a leak as genuine.

The iOS lanes no longer upload `/tmp/sim.logarchive`. The archive is a
full-device binary capture the scanner cannot read, so the diagnostics step
exports Haven's own lines to `sim-unified.log`, the LAST 64 MiB of the whole
device to `sim-unified-full.log`, deletes the archive, and runs both exports —
with the transcript and the relay logs — through the same delete-on-leak gate
before the upload step can see them. The tail, not the head: `log show` emits
chronologically and the archive opens at BOOT, so a head cap kept the boot
storm and threw the run away — in CI run 35280144455 every lane's capped export
ended 15-20 minutes BEFORE its app launched, because 64 MiB is about two
minutes of a booting simulator. The archive ends at the `log collect`, so its
tail is the scenario; what a lane logs beyond the cap while it runs is still
discarded with the archive.

## Failure mode 13 — the runtime log scanner fails a lane (rc 1, 3 or 4)

**Where it runs.** Every lane in the fleet. Each job that captures a device,
simulator or test log declares `HAVEN_LOGSCAN: "true"` at job level, builds
`haven-logscan`, rotates `/tmp/haven-soak/needles/` before its first capture,
and runs every capture through `tooling/e2e/ci/scan-logs.sh` — the
key-material floor (`scan-logs-for-secrets.sh`, failure mode 12) AND
`haven-logscan scan` — before anything echoes or uploads it: the runner's gate
(`logscan_gate` / `logscan_gate_dir`, from `tooling/e2e/ci/logscan-gate.sh`)
over the logcat, drive and per-target logs it wrote, and the workflow's `Scan
captured logs for secrets before upload` step over the relay, diagnostics,
proxy and unified-log exports, both against the same manifest.
`check_logscan_wired_everywhere.sh` is what keeps every capture on that path;
`check_wire_oracle_lane_reachable.sh` link 5 is what keeps the flag on. What
the manifest holds depends on the lane's profile (`HAVEN_LOGSCAN_PROFILE` on
the iOS lanes, the runner's own choice elsewhere):

* **`proxy`** — `e2e-android.yml` and `e2e-ios.yml`, the two recording lanes:
  sealed from the declaration sidecars the recording proxy wrote
  (`*.needles.decl`), with the host needles added. A sidecar the drive never
  wrote is rc 3 before the seal (`no needle declaration sidecar`: the drive
  never reached the proxy's declaration channel — the proxy not running, not
  the recording one, or started before the needle directory was rotated), and
  `check-proxy-sidecar-summary.sh` must have read a healthy recorder summary
  first. On `e2e-ios.yml` the retry command rotates the directory per attempt
  (`rotate-needle-dir.sh`), so a stalled attempt's sidecar never reaches the
  next attempt's seal.
* **`host`** — every proxy-less device lane (`e2e-profile`, `e2e-integration`,
  `e2e-relay-customization`, `e2e-flakiness-stress`, `e2e-background-catchup`,
  the seven Android scenario lanes, the three iOS scenario lanes): nothing was
  declared over a channel, so the seal declares what the host knows —
  `tooling/e2e/ci/host-needles.sh`: the four fixed harness seeds derived to
  pubkeys (`--host-seed`; the seed itself is never printed and never written
  to the manifest), the three role coordinates, the canary coordinate and the
  two canary name stems, plus the lane's own injected point where it has one
  (`--host-decl coordinate=…`, the B1/B3/B4/B5/B6 constants). Sealed
  `--declared-plants none`: no channel could hand the app a token to print, so
  no Dart plant is reconciled, while the `rust`/`kotlin`/`swift` shape plants
  still are. A multi-target lane seals its one manifest before the first
  target (with its `--floor drive=…`) and every later gate reuses it (so does
  `e2e-ios.yml`'s second drive, under `proxy`: the seal writes `create_new`,
  and reuse is right only because the mirror drive declares nothing new). The
  directory gate types each `*.log` by name — `*logcat*`, `*drive*`, the
  exact relay-producer names listed in `logscan-gate.sh`
  (`LOGSCAN_RELAY_LOG_NAMES`: `strfry*.log`, `relay.log`,
  `relay-profile-*.log`, `haven-local-relay*.log`, B5's `relay-poll.b5.log`
  and promoted relay exports, B9's `relay-backlog-event.b9.log`) as `relay` —
  and then by CONTENT: a file whose own lines are `adb logcat -v threadtime`
  entries is a `logcat` sink whatever it is called
  (`logscan_is_logcat_format`; a majority of the first twenty non-blank lines,
  at least five of them, must carry the threadtime header). That rule exists
  because B1's `post-pause.window.log` — the capture sliced out between the
  handoff and the hold — was typed `diag`, which runs the structural rules over
  the PLATFORM's lines as if Haven had written them: 342 hits in CI run
  35280144455, every one of them vendor furniture, while the full capture it
  was cut from scanned clean. Anything left — an unknown `relay-` prefix and
  the blossom log included — is `diag`, and a directory with no `*.log` at all
  is rc 3: a run that recorded nothing cannot be proven clean. Line floors are
  per sink CLASS and summed over its files, so a slice rides on the full
  capture beside it; a slice with no full capture in the same directory is rc 4.

  Two captures are REDUCED before they become files, because their raw form is
  legitimately full of what Rule 15 forbids uploading and no sink class could
  forgive it. A platform `dumpsys package <pkg>` dump is piped through
  `logscan_permission_extract`, which keeps the `android.permission.…` lines
  the lane actually greps and drops the install paths, signing digests and
  dexopt state (B3/B5/B6 were uploading the dump whole, and S4 read its
  install-path furniture as a blob twice per dump in run 35280144455). The
  Android profile lane's `docker logs blossom` is piped through
  `logscan_http_log_summary`, which emits only counts: a Blossom access log is
  the SERVER's view of its client — blob digests, the uploading pubkey, the
  base64 kind-24242 auth header — and unlike strfry it has no rules-off class
  to be forgiven by. Both reductions are still scanned as `diag`. If a
  permission assertion fails, read the extract, not a dump that no longer
  exists; if the blossom summary says `lines: 0`, the server saw no request at
  all.

  One NEEDLE exemption applies to the three iOS lanes that INJECT a fix (b4,
  the auth-tier lane, the background-publish lane): on an `ios` capture the
  `coordinate` class is not searched on records whose process is `locationd`
  AND whose emitter is `com.apple.locationd.Position` (`policy.toml`'s
  `emitter_scoped_out`). `simctl location set` hands the location daemon the
  very number the lane then declares, so that program's own records are the
  SOURCE of the value rather than a place it leaked to — CI run 35311161479's
  `e2e-ios-real-gps` was rc 1 on nothing else. Everything around it is
  unchanged: every other class is still searched on those records, the same
  coordinate under any other program (Haven's own, `apsd`,
  `CoreSimulatorBridge`, or that same subsystem inside Haven's own process) is
  still a leak, the structural rules never read that emitter's lines anyway,
  and no other sink is affected. A coordinate hit on an iOS capture is still a
  real one.
* **`rules-only`** — `rust-check.yml`'s four tee'd `cargo test` transcripts
  and `coverage.yml`'s two tee'd `flutter test` transcripts: no manifest,
  because a unit-test run mints nothing declarable. The structural rules and
  the line floors run (`--exempt-endpoint 127.0.0.1`, for the `#[ignore]`
  reason that names a loopback Blossom URL) and the summary says `rules-only`
  — it certifies that the rules ran, not that any declared value is absent. A
  hit there is furniture the crate's fixtures must learn (`furniture.*.log`),
  or a stray `println!`/`debugPrint` of an identifier under test; it is never
  fixed by loosening the lane. One shape a test print adds on its own: the
  `--exempt-endpoint 127.0.0.1` exempts the BARE IPv4 literal from S12 and
  nothing else, so a loopback URL such as `ws://127.0.0.1:<port>` printed by
  a test (a relay stub announcing itself, an assertion message naming the
  endpoint) is an S7 hit that reds the job and deletes the transcript. The
  fix is the print — a `logAliasHandle(LogAliasClass.relay, …)` or no URL at
  all — never a second exemption. One shape the TOOLCHAIN adds on its own is
  narrowly exempt: on a `rust-test` sink, **S2 and S6 only** are skipped on a
  `Compiling|Checking|Downloaded <crate> v<semver> [(<source>)]` line
  (`policy.toml`'s `cargo_status = "exempt"`), because a cold coloured run
  prints the public pinned git revision of every git dependency and the name of
  every crate before a test starts. Everything else about that line is still
  scanned — S1, S5, S7, S12 and the rest all fire on it, and the needle search
  reads every byte — and cargo's other status lines (`Finished`, `Running`,
  `Doc-tests`, `Updating`, `Downloading`) are not exempt at all. So a hit on a
  cargo-shaped line is a real print, not furniture; the one thing the exemption
  hides is a 32–63-hex run or a geohash-shaped token in the crate-name or
  source slot of that exact shape, which is the residual `tooling/logscan/README.md`
  declares. Containment is detection only: the transcript already streamed into
  the job log. `--rules-only` is forbidden outside those two workflows.

The wrapper folds the two verdicts as `1 > 2 > 3 > 4 > 0`; its last line names
both scanners' codes, the sink count and the manifest's basename (or
`rules-only`, or `no manifest resolved from the needle directory`). Workflows
hand the wrapper the needle DIRECTORY (`--manifest-dir`), never a glob: it
resolves the one `*.needles.json` itself, after the key-material floor has run.
An empty directory is rc 4 and means the lane died before it sealed a manifest;
a directory that does not exist is rc 4 and means the path is wrong; two
manifests is rc 2 — the directory was not rotated, and the wrapper will not
choose between this run's needles and a stale run's. The failing line above it
is one of three shapes:

**rc 1 — `LEAK: <sink>:<line> [<class>/<encoding>|<rule>] tag=<tag> ×<n>`,
then `secret-leak guard tripped … removed the scanned logs`.** A declared
identifier (a pubkey, group id, event id, name, coordinate or relay URL the run
minted or the host declared — in any of the encodings the manifest expands it
into) or a structural shape (a bare 64-hex run, a bech32 string, a coordinate
pair, a URL, an IP, a 32-element array…) is in a captured log. **Evidence is
withheld by design**: the wrapper deleted every sink it scanned before
returning, so the failure artifact carries none of them and the job log names
only the sink, the line number, the class and the encoding — never the value.
Reproduce locally against your own emulator or simulator (the same runner
script and scenario; on a proxy lane the proxy started after the needle
directory was rotated, on a host lane nothing more than the checked-in
constants) and run `haven-logscan scan … --disclose-values` there to read the
matched text; that flag is banned from every workflow and runner by
`check_wire_proxy_test_only.sh`, and must stay so. Then fix the log site
(CLAUDE.md, Log anonymity: the value is the leak, whatever the level; use a
`log_alias` handle, a bucket or a relative offset). Do not re-run: the needle
set is re-declared on every run and the match is deterministic.

**rc 3 — `positive control missed …`, `absent`, `empty`, `unparseable`, a
segment-count or ledger mismatch.** UNUSABLE: fix the capture, not the app. On
a proxy lane every run plants a per-run token at the start and the end of the
drive (`logscan-plant-dart-open-…` / `…-close-…`, declared over the proxy) and
the app's own start-up plants (`logscan-plant-rust-open-…`, `…-kotlin-open-…`,
`…-swift-open-…`), and the scanner requires each in the sink class it must
reach; on a host lane only the shape plants are required, and only in the
classes the policy names (`declared_plants_expected` in
`tooling/logscan/policy.toml`). An `ios` sink's plants prove less than
Android's: the Swift plant is a fixed literal and `log collect` spans the
whole simulator boot, so a found plant says the backend reached this capture
at some point in this boot — not that THIS run's process did, which is what
Android's per-run token says. Both iOS plants were silently unreachable until
CI run 35280144455, and each for its own reason, so if one goes missing check
these first. The Swift plant sits inside `#if DEBUG`, which is a Swift
compilation condition rather than the `DEBUG=1` preprocessor macro the project
sets for C/ObjC: it is true only while the Runner target's
`SWIFT_ACTIVE_COMPILATION_CONDITIONS` names DEBUG, and while that setting was
absent the plant — and every other `#if DEBUG` in the target, the two wake
handlers' diagnostics included — compiled to nothing. It is also an `os_log`
under the `haven_ios` subsystem rather than an `NSLog`, for two reasons: an
`NSLog` record's emitter is Foundation's, so the scanner could not own the line
it proves reached the capture, and `os_log` with no `type:` is
OS_LOG_TYPE_DEFAULT, which logd persists. The Rust plant is a
`log::debug!`, which the `oslog` crate maps to OS_LOG_TYPE_INFO, which logd
keeps in a wrapping MEMORY buffer and never persists: in that run it survived
`log collect` in the two lanes whose app lived 15 s and 24 s and was gone from
the two that ran for minutes, while the same launch's `warn!`/`info!` lines
survived in all four. `boot-ios-sim.sh` now marks the `frb_user` subsystem
persistent right after boot; if that `log config` call warns, expect the Rust
plant to be duration-dependent again. A missing plant means the sink was not read end
to end — the capture died, rotated, or was never flushed, or the file scanned
is not the file the run wrote — so the "no leak" it would otherwise report is
a statement about nothing. Check the logcat capture (`adb logcat -c` and the
background `adb logcat` in the runner), the final-attempt slice, and whether
the drive reached its `close` plant; a run that failed before the end of the
drive fails here too, and that is the intended second signal, not noise. On an
`ios` sink (`sim-unified.log`, `sim-unified-full.log`) every line is parsed as
`log show` output into process, pid, emitting library, `[subsystem:category]`
and body, in the rendering the lanes capture
(`<date> <time+tz>  <host> <process>[<pid>]: (<library>) [<sub>:<cat>] <msg>`)
or in the `<<Type>>:` and columnar variants. Ownership is the record's EMITTER
— its subsystem, else its library, else its process — because inside the app's
own process every Apple framework logs as `Runner` too, so a process test would
put libxpc's, UIKitCore's and CoreLocation's output under Haven's structural
rules. Haven's emitters are `frb_user` (the Rust core's oslog subsystem),
`haven_ios` (the subsystem every Haven Swift log call names — `NSLog` would
carry Foundation's emitter instead, and `Foundation` is the library on tens of
thousands of vendor lines per capture), `rust_lib_haven` and `Runner` (Haven's
images), and `Flutter` (the engine's image, which carries Dart's own
`flutter: <msg>` output; the loopback VM-service URL on it is forgiven by the
endpoint exemption the lane already claims for its own relay). A line that does not parse is un-owned (needles still searched, rules
skipped), and a capture in which **every** line is unparseable is rc 3 — the
file is not a `log show` export (a truncated or binary capture, a `--style`
change in the diagnostics step), not a clean device. A LEAK line from this sink
carries `tag=<process>/<subsystem-or-library>` owned or not, so a hit in the
device-wide export names the program to go and read; that export also holds
HOST processes (`CoreSimulatorBridge` alone is a quarter of a boot window), so
the emitter is not necessarily inside the simulator.

**rc 4 — a floor unmet: `declaration floor`, `line floor`, `no manifest`.**
META-FLOOR: fix the scenario. The seal requires the lane to have declared at
least what its shape implies — on the Android core-flow lane `--expect
pubkey=3 --expect coordinate=4 --expect circle_name=1 --expect petname=1
--expect nostr_group_id=1 --expect mls_group_id=1 --expect event_id=3` (three
roles, the three role fakes plus the canary coordinate, one circle name, one
petname, at least one circle, three deterministic event carriers); on a host
lane the library's own floors over the host needles — and the scan requires
each sink to be at least its line floor. A floor is the anti-vacuity check: it
turns "the scan read an empty or truncated file and found nothing" into rc 4
instead of a green, so it is calibrated to the smallest COMPLETE capture of its
class and never to what would make a lane pass. `tooling/logscan/policy.toml`'s
per-class `min_lines` are the class defaults — 2000 for a logcat or a
unified-log export, 100 for a drive transcript, 20 for a test transcript, 5 for
a proxy log, 1 for a relay log (the hermetic host relay prints one listen line
for a whole run) and 1 for a diag. A lane whose captures are legitimately
smaller passes its own `--floor <class>=<n>` at its seal rather than lowering a
default, with its basis and the runs it came from stated beside it: integration
and relay-customization take `drive=18` (each target is gated as
`--sink drive=<final>,<full>` and a floor sums its class's files, so it is twice
the 9 lines the host prints per slice), `logcat=300` (logcat is captured per
target, not per scenario) and `relay=7`; background-catchup and FGS-publish take
`drive=9 relay=7` (both keep the app running, so both carry the ninth line),
KeyPackage-rotation, real-GPS, provider-toggle, clock-skew and network-reconnect
`drive=8 relay=7`, and permission-revocation `drive=7 relay=7`
— that lane alone drops the verdict line from its count, because ACT 1's green
shape is the app dying under the driver, which ends the transcript in a
`DriverError` instead.

For a **`drive` sink the line count is not what proves a test ran** — a
transcript's length is the tool's own output plus whatever logcat furniture the
device happened to forward, so the floor that clears the shortest COMPLETE one
also clears a transcript in which nothing ran, which is how a complete 19-line
capture went rc 4 under a floor of 20 in CI run 35464818348. The proof is a line
the test reporter itself wrote, which the scanner demands of every `drive`
capture through `policy.toml`'s `proof_of_run`; its absence is rc 4 saying "no
test ever started", and no `--floor` can remove it. Which line that is depends on
the reporter `flutter` picked, so the pattern is an alternation: the compact
reporter's progress line (`HH:MM +N: <name>`, forwarded by logcat as
`I/flutter ( pid): 00:00 +0: …`), and the **github** reporter's per-test
`✅ <path>: <name>` / `::group::✅ …`, which `test_core` selects whenever
`GITHUB_ACTIONS == 'true'` — i.e. every hosted `flutter test`, whose transcript
has no progress line at all, which is what made CI run 35478132251's Flutter
coverage job rc 4 over 4 673 passing tests. An ANDROID drive floor is
therefore calibrated to the lines `flutter drive` prints on the HOST alone — the
`Installing …` line (there is no already-installed shortcut in
`AndroidDevice.startApp`), the six `VMServiceFlutterDriver:` connect lines, the
verdict and `Leaving the application running.` where the lane keeps
the app alive — and never re-measured from a transcript that also carries
forwarded device chatter. That skeleton is 8, or 9 with `--keep-app-running`,
in EVERY drive transcript of four green runs (35311161479, 35376588206,
35397118356, 35524002720) while the transcripts themselves swing by half their
length, so every Android lane's floor is now derived from it and each runner's
`--self-test` reds if its floor exceeds its own skeleton fixture.

Four of the six connect lines are unconditional — `Connecting to Flutter
application at …`, `Isolate found with number: …`, `Isolate <n> is runnable.`
and `Connected to Flutter application.` — and two are not: `Isolate is paused at
start.` and `Attempting to resume isolate` sit inside
`if (isolate.pauseEvent.kind == kPauseStart)` in `flutter_driver`'s
`vmservice_driver.dart`, whose sibling branches print `Isolate is paused
mid-flight.` or `Isolate is not paused. Assuming application is ready.` and
whose own comment names the race — another tool, "usually a debugger", having
resumed the isolate first. Counting them is still honest here, and that is the
whole reason the floor stays a lower bound: `flutter drive` defaults
`--start-paused` to `true` (`drive.dart`'s `startPausedDefault`), and in drive
mode flutter_tools launches the app, starts DDS and hands the VM to the driver
script without resuming anything, so a freshly launched app IS at `kPauseStart`
and the other branches are reachable only when something outside the lane
resumed it. Nothing in these lanes does, which is why both lines are in every
measured transcript — three of three drives in the background-catchup lane of
run 35524002720, to name the capture that is cheapest to re-read. If a lane ever
attaches a debugger, its floor drops by two before that lane lands, not after.

That proof has a second half, `proof_of_run_excludes`, because both reporters
render the SUITE they are LOADING through the very shape above and a load is not
a run. The expanded reporter opens every iOS transcript with
`00:00 +0: loading <path>` — **before** the Xcode build, not after it — and the
github reporter renders a suite that failed to load as
`::group::❌ loading <path> (failed)`; a third exclusion covers
`HH:MM +N: Some tests failed.`, which `_onDone` writes as a progress line for a
run whose suite never loaded. Each is anchored on the reporter's prefix to its
left and the suite path's `.dart` to its right, so a test whose NAME says
"loading" is still proof. Until they existed an iOS capture of a build that
never launched read as a run, which is why the iOS floors were measurements.

An iOS capture carries no forwarded device chatter, so its host skeleton is the
four lines a `flutter test -d <udid>` transcript always has: the reporter's
`HH:MM +N: loading <path>` and its first test-start line, and flutter_tools'
`Running Xcode build...` / `Xcode build done.` pair, which an incremental build
prints exactly as a cold one does. Every iOS lane's floor is now that **4**, and
`run-ios-sim-scenario.sh` refuses a `HAVEN_LOGSCAN_DRIVE_FLOOR` outside `1..4`
at SCRIPT START — before the arguments are read, before the build, before
anything can have been captured — so no iOS lane can be re-pinned from a
transcript's length, and every iOS lane is covered because every one of them
(b4, b7, the profile lane's iOS job, background-publish) reaches the gate
through this script. The refusal deliberately does NOT live on the gate path:
one that did meant a mis-set floor skipped the key-material floor and the
scanner both, leaving the transcript uncontained while the `if: failure()`
upload still ran. What
the old numbers caught and 4 does not — a drive that built and never launched —
is the fixed `proof_of_run`'s job, at any floor.

The core-flow iOS lane keeps the default of 100 and clears it a different way:
it drives TWO scenarios through the one fixed transcript path, which the runner
truncates per invocation, so each invocation preserves its own as
`/tmp/flutter-ios-test.<scenario>.log` and both the second gate and the
workflow's scan step weigh them together — without that, the
mirror check's ~14 lines would be rc 4 on every green run. The four
single-scenario iOS lanes all take `drive=4`, the host skeleton above — iOS
real-GPS, the profile lane's iOS job, iOS auth-tier (per tier) and iOS
background-publish, whose belt sums two copies of the one transcript and passes
the same number, a floor being a minimum. They replace 22, 24, 27 and 56, each
of which was half a transcript measured in CI run 35280144455 (45, 49, 54 and
112 lines) and each of which would redden a lane that printed less than it did
that day. Every strfry lane takes `relay=7`
for the same reason: strfry's `docker logs` dump opens with a fixed 9-line
startup block and grows only with traffic (9-49 lines across the fleet's green
runs, exactly 9 where the relay serves nothing it logs), while the same command
against a container the runner has already torn down prints ONE line of error
text, and with the structural rules off for this class the floor is the only
thing that tells a dead capture from a live one. Below
either kind of floor, the scan proved too little to be called clean. `no manifest` on a device lane means the
seal never ran or refused — read its error above; on a rules-only lane it is
the summary line, not a failure.

rc 2 (`GUARD BROKEN`) is the instrument, not the run: the scanner binary
absent or not executable (`Build the runtime log scanner` failed, or
`HAVEN_LOGSCAN_BIN` points elsewhere), a usage error in the wrapper call, an
iOS lane whose `HAVEN_LOGSCAN_PROFILE` is neither `proxy` nor `host` (refused
before the build), a mis-shaped manifest, an expired or dangling allowlist
entry (`check_logscan_policy.sh` catches the allowlist's shape on every push,
without the crate). It is never a skip: an absent scanner reds the lane, and
the key-material floor has already run and contained by the time it is
reported.

The declaration sidecars, the sealed manifest and the wire-canary manifest hold
the run's identifiers verbatim. They are never uploaded, never read into a job
log (`check_wire_proxy_test_only.sh` bans every read of them from a workflow or
runner), and are removed by every lane's final `Discard needle manifests` step
on every outcome, after its last upload (`check_logscan_wired_everywhere.sh`
requires the step, and the pre-capture rotation, of every recording or sealing
lane). The scanner's findings reports (`/tmp/logscan-report*.ndjson`,
`/tmp/<lane>-logscan/*.ndjson`, `/tmp/ios-logscan/*.ndjson` — sink:line and
class only) are not uploaded either — the same guard bans every `.ndjson` from
an upload path — so the LEAK lines in the scanning steps' logs are the record.

## Failure mode 14 — `soak-core-pr` is red

The soak lane (`soak-core.yml`, driven by `tooling/e2e/ci/run-soak-core.sh`) is
not an app lane: there is no emulator, no simulator and no APK. It builds a
whole Haven world in ONE process — several devices with real MLS stores and
real live-sync engines, against hermetic relays it breaks on a seeded schedule
— and grades `haven-core`. So the "diagnose first" rule above does not apply
here in its usual form: there is no unhealthy emulator to rule out. What there
is instead is an rc that already says which half is at fault.

**Read the exit code first. It is the diagnosis.**

| rc | It means | Where to look |
|---|---|---|
| 1 | a declared invariant broke, OR a capture carried a declared identifier | `VIOLATION.marker` vs `LEAK.marker` in the uploaded tree. A violation keeps its first-violation snapshot; a LEAK deleted the tree on purpose and left one line saying so, with the class/encoding/`sink:line` in the job log and no value anywhere |
| 2 | **the rig is broken, not the subject** | the rig leaked an `Arc` and the session stayed live; `allow_ws_loopback_for_test` was called twice; S13's key set-difference was not exactly one, i.e. the upstream schema moved under the pinned engine. Do not open a product issue for an rc 2 |
| 3 | the run proves nothing | a scheduled fault never fired, an expectation floor was unmet, a shape plant was missed. The world, not the subject |
| 4 | the run proves too little | a manifest with no searchable term, or a declaration floor unmet. Also the rig, not the subject |

Then the **banner**, which is the first file in the uploaded tree and is
written BEFORE the run starts precisely so an rc-3 run still has its seed on
record. It carries the profile, the seed, the short commit, the rustc version
and the 8-hex schedule tag — enough to reproduce:

```
scripts/run_soak_local.sh core --profile pr --seed <seed> --count 3
```

3/3 is a defect. 1/3 is a race in the rig, which is itself a bug to fix in the
rig — never a retry and never a loosened bound.

Two failures that look like the product and are not:

* **An anonymous 124 with no rc line.** The inner deadline
  (`run-with-deadline.sh 6m`) fired. The rig carries exactly one inner bound by
  design (docs/SOAK_LANE.md explains the arithmetic), so this says only THAT it
  hung; the timeline in the uploaded tree is what says where.
* **`if-no-files-found: error` on the upload step.** The evidence tree was
  empty, which after a LEAK it is not (containment leaves one file). An empty
  tree means the rig never reached the point of writing its banner — look at
  the redirected stdout capture, which is in that same tree and is scanned like
  every other file.

Everything else — what green does and does not prove, which of PLAN §2.1's
S1–S9 this actually grades, and which scenarios have no lane execution yet — is
in `docs/SOAK_LANE.md`, and is worth reading before concluding that a green
soak lane covers a behaviour.

## Failure mode 15 — "Android SDK provisioning failed" (infrastructure; no test ran)

**Symptom.** An Android lane reds on the step **Provision the Android SDK**,
with one annotation:

```
Android SDK provisioning failed for package system-images;android-34;google_apis;x86_64
after 3 attempt(s) or a spent 360s budget. This is INFRASTRUCTURE, not a product
failure: sdkmanager could not install a package the emulator needs, and no test
ran in this job.
```

**What it means.** Exactly what it says. The step runs before the lane's first
use of `reactivecircus/android-emulator-runner` and installs the four packages
that action needs — `platform-tools`, `platforms;android-<api>`, `emulator` and
the system image — retrying each and **verifying it on disk** rather than
trusting sdkmanager's exit code. A red here is a download that did not land, or
a package that landed unusable. Nothing was built, nothing was driven, no
assertion was evaluated: it is never a product regression, and the artifacts
hold no drive log because there was no drive.

The step's own exit code separates the two ways it can end:

| rc | It means |
|---|---|
| 2 | the step is broken, not the lane: bad arguments, or no `sdkmanager` under `$ANDROID_HOME/cmdline-tools/latest/bin` **and none on `PATH`**. Look at the runner image, not the network |
| 3 | provisioning failed — infrastructure. The `::error::` names the package |

**Why the step exists.** Without it the action installs the packages itself,
with bare `sdkmanager --install` calls it tries exactly once. In CI run
35524002720 (`e2e-relay-customization`) the emulator's download failed
(`Warning: Failed to download package!`), `sdkmanager` exited non-zero and the
action stopped at the install — no AVD was created and nothing was booted. The
LAST thing the job printed, though, was the action's unconditional teardown:

```
error: could not connect to TCP port 5554: Connection refused
```

— a message about the emulator, from a job whose real fault was a transient
download, which is why triage goes to the wrong place. CI run 35280144455
(network-reconnect) had the other shape of the same class: a corrupt emulator
zip, where the package directory is complete and the binary does not run. The
retry answers the first; grading each attempt by what is on disk (never by
`sdkmanager`'s exit code, in either direction) answers the second.

**Read the reason before blaming the mirror.** Every rejected attempt prints why
under its `did NOT verify` line: no directory, no sdkmanager manifest, no
launcher, or the emulator probe's exit code and last lines. The probe is
`emulator -no-window -version`, because `-no-window` is what selects the
headless qemu binary the lanes boot; the windowed one links desktop libraries a
runner does not have. CI run 35536892150 is the case where the fault was the
verifier: the probe then omitted `-no-window`, the launcher printed its version
and exited 255, and a sound emulator was rejected and deleted in all thirteen
lanes with `sdkmanager rc 0` on every attempt. The same package failing in every
lane at once, with rc 0, is that signature — a mirror outage is not that tidy.

**If it recurs.** Three attempts per package (10 s then 30 s apart), each capped
at 180 s, under a 360 s whole-step budget — so a red means three failures or a
genuine stall, not one unlucky request. Re-running the job is reasonable exactly
once; a second red in a row is an SDK-mirror outage, not a flake. One package is
deliberately still un-hardened: the action's own `build-tools;<latest>`, whose
version it resolves at run time and which ships on the runner image. A "Failed
to download package!" naming `build-tools` therefore still fails the old way —
inside the action, with the emulator's adb-port message.

**What keeps it wired.** `scripts/ci/check_android_sdk_provisioned.sh` fails the
repo-guards job if any job that uses the emulator action lacks the step, places
it after the action's first use, gates it on an `if:`, or passes api/target/arch
that differ from what that job's action steps declare. It also fails any
emulator step whose `emulator-options` lacks `-no-window` (or is absent): the
step verifies the headless emulator binary, so that is the one a lane must boot.

## Failure mode 16 — `E2E Flakiness Stress` fails the same scenario every iteration

`e2e-flakiness-stress.yml` is the one lane that drives `e2e_combined.dart` with
**no recording proxy in path**: it points the app straight at strfry
(`HAVEN_E2E_RELAY: ws://10.0.2.2:7777`) and mints no `HAVEN_WIRE_SENTINEL`, so
the app compiles `TestRelay`'s default token and `wireRecorderDeclared` is
false. Everything that speaks the proxy's control vocabulary is therefore gated
on `wireRecorderDeclared`: the needle declarations, the MLS-group-id
announcement, the canary manifest, and the wire-journal sentinel.

From 2026-08-12 the sentinel was not. Every iteration of every nightly run
failed the last test in the file with `Bad state: no wire-journal sentinel ack
within 15s. Either this connection does not run through the recording proxy, or
the proxy is not recording.` — literally true and entirely expected on this
lane: the harness verb went to a real relay, which neither intercepts nor
answers it. The lane exists to measure this scenario's flake rate, and for that
month it measured nothing. No push-triggered workflow runs it, so nothing
surfaced the failure.

If that message appears here again, the cause is a CALLER that lost its gate,
never the relay. `TestRelay.emitWireJournalSentinel` refuses the compiled-default
token before anything reaches the socket;
`haven/test/lints/wire_sentinel_recorder_gate_test.dart` fails on a PR when the
scenario's `if (wireRecorderDeclared)` no longer covers EVERY emit; and the
"recorder gate" group in `haven/test/e2e/test_relay_transport_test.dart` pins
that an undeclared build writes no frame at all. On the WIRED lanes
(`e2e-android.yml`, `e2e-ios.yml`) the same message still means the app was
pointed past the proxy or the proxy stopped recording, and a missing sentinel
there is a META-FLOOR at every host oracle, never a pass.

The same lane then failed a second way once the log scanner reached it:
**rc 3, "a Dart plant token in a scanned sink matches no declaration"**. The
harness prints its plant token whether or not a recorder is listening and
declares it only when one is (`log_needles.dart`), so on a
`HAVEN_LOGSCAN_PROFILE: host` lane the token is undeclared by design, and the
lost-declaration rule applies only to a manifest sealed WITH a declaration
channel. One problem is reported per sink class carrying the token, so one
token in logcat and drive reads as two. Conversely, **rc 2 "…but a
`*.needles.decl` sidecar sits in /tmp/haven-soak/needles"** means the lane ran
the recording proxy while sealing `host`: fix the profile
(`HAVEN_LOGSCAN_PROFILE` / `WIRE_UPSTREAM`), never the manifest.

Standing rule: a nightly-only lane is invisible to a push. After any change to
the scanner, the gate or the shared harness, read the next morning's nightly and
stress results, or replay their uploaded artifacts.

## Failure mode 17 — iOS bg-publish: the drive "did not complete" right after `BACKGROUND_SHARING_DISABLED`

The transcript ends at the disable, the test AND its `tearDownAll` are reported
as `did not complete`, the drive exits 79, and `ios-flake-lib.sh` correctly
refuses to retry it (the verdict is `genuine`, which is not the one retryable
signature). **This is normally not a failure at all** — it is iOS reclaiming
the app inside P3's settle window, and P3 is the phase that takes the app's
right to run in the background away.

What actually happens, measured on CI run 35622556197 (`when-in-use-live-sync`,
`sim-lifecycle.log`): the disable drops every CoreLocation claim ~0.2 s after
`BACKGROUND_SHARING_DISABLED`; `runningboardd` invalidates the assertion
`locationd` held on the app one second later; the shared `FinishTask` grace
that replaces it expires ~30 s on; RunningBoard suspends and then terminates
the process for not invalidating it — `OS_REASON_RUNNINGBOARD`, code
`0x2182bad2`. **No jetsam, no crash report, no watchdog** (`0x8badf00d` appears
nowhere). The assertion nobody ended is the DEBUG Flutter engine's own
`Flutter debug task`, which UIKit warns about in every run of this lane
(`"was created over 30 seconds ago … this creates a risk of termination"`).
Whether the process gets to acknowledge the suspension in time is an OS
scheduling race, which is why the same leg is green on most runs.

Since then the wrapper does not end there. It holds P3's window open from the
host and asks the relay — `tooling/e2e/ci/bgp-wire-probe.dart`, run against
the lane's own `haven-local-relay` — whether any kind-445 was created inside
it, and prints one of four verdicts. Read the log for them:

| Line | Meaning | Who to blame |
|---|---|---|
| `P3 HOLDS on the wire` | silent for the whole window, process stayed gone, disable applied in-process | nobody — the lane goes green with the two markers the dead process could not print excused BY NAME |
| `ERROR: P3 — kind-445 event(s) reached the relay INSIDE the settle window` | publishing outlived consent, from the app or from a background relaunch | the product (privacy Rule 10) |
| `ERROR: P3 — the settle window ended with the app RUNNING again` | something re-armed a background wake after consent was withdrawn | the product |
| `ERROR: P3 has NO verdict on this run` / `could not read the relay` | the oracle failed, not the promise | the harness — fix the probe, never the expectation |

Two things make that green trustworthy, and both are pinned by check 19 of
`scripts/ci/check_ios_background_publish.sh`: the host counts EVERY kind-445 in
the window, which is only an answer because the drive disposes the synthetic
peer **before** P3 (the host cannot tell two authors apart — ephemeral
per-message keys, one shared `h` tag); and the probe carries a control question
whose answer cannot be zero, so an unread relay is never reported as a silent
one. The probe runs its own `--self-test` in the wrapper's preflight, so an
instrument that stopped reading fails the lane at minute two instead of
passing P3 for free at minute forty.

If the same message appears with the app `running` or `unknown` instead of
`gone`, none of the above applies: the drive died with its app still there, and
that is the drive's own failure to explain from its transcript.

## What these lanes do NOT cover

The iOS simulator keeps the app alive and the VM-service attached, so it does
**not** reproduce real-device background **suspension**. A "background execution
stops" bug will not surface here — that class needs a physical device, which is
out of scope for GitHub-hosted runners. The one exception is the window after
`BACKGROUND_SHARING_DISABLED`, where the app deliberately holds no claim and
the OS does take it (failure mode 17) — proving that publishing has stopped, not
that background execution survives.

## Feature flags seen in these lanes

| Flag | Meaning | Default |
|---|---|---|
| `HAVEN_LIVE_SYNC` | M11 persistent live-sync engine (vs the retained poller) | `true` (LIVE since M11 Phase B); every e2e lane forces it explicitly |
| `HAVEN_E2E_NO_BACKGROUND` | skip M7 FGS/background init (single-engine for `flutter drive`) | `false` (prod), `true` on e2e_combined only |
| `backgroundCatchupEnabled` | M7-E background catch-up (Dart const) | `true` (LIVE) |
| ~~`enablePeriodicSelfUpdate`~~ | M5 hourly self-update | **REMOVED (Unit E)** — the flag and `self_update_provider.dart` are deleted; nothing re-keys on a timer |

## Pointers

- Migration state: memory `project_wn_relay_epoch_migration_plan`,
  `docs/M11_ROLLOUT.md`, `docs/M7_BACKGROUND_SHARING.md`.
- REV-1 (distributed SelfRemove fork): `docs/M11_ROLLOUT.md`.
- The `check_m7_native_wake_guards.sh` guard pins the M7-E released state; its
  check 14b pins `liveSyncEnabled`'s `defaultValue: true` (M11 Phase B shipped
  the engine ON), so a silent re-inert to `false` turns it red. An intentional
  live-sync rollback (M11 plan §8) reverts 14b together with the default it
  pins — it correctly fails first.
