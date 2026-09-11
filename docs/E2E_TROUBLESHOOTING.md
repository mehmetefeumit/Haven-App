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
oracle is not.

| Workflow | What it runs | How | Relay |
|---|---|---|---|
| `e2e-android.yml` | `e2e_combined.dart` (real Alice UI + synthetic Bob/Carol/Dave FFI peers) | `flutter drive` on an AVD | strfry container, `ws://10.0.2.2:7777` |
| `e2e-ios.yml` | `e2e_combined.dart` + `ios_bg_mirror_test.dart` | `flutter test -d <udid>` on a booted simulator | host-native relay, `ws://localhost:7777` |
| `e2e-background-catchup.yml` | M7 background catch-up runtime proof (4 phases + a guest reboot) | `run-m7-background-catchup.sh` under `reactivecircus/android-emulator-runner` | strfry container, `ws://10.0.2.2:7777` |
| `e2e-live-sync.yml` | The SAME two lanes, flag-ON (`HAVEN_LIVE_SYNC=true`) — a manual re-run of what `ci.yml` already gates on | `workflow_dispatch` only | — |
| `e2e-integration.yml` | seven component targets (`smoke_test`, `app_test`, `keyring_test`, …), one after another | `run-integration-tests.sh` → `run-single-avd-scenario.sh` per target, on one AVD | strfry container reset per target, `ws://10.0.2.2:7777` |

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
block on `cmd package wait-for-handler` followed by
`am wait-for-broadcast-barrier --flush-broadcast-loopers`, so the broadcast is
delivered before anything launches the app. PackageManagerService posts the
send to its own handler and only then answers the installer
(`android-14.0.0_r1`, `InstallPackageHelper.handlePackagePostInstall`), so a
bare barrier taken as `adb install` returns can pass before the broadcast is
enqueued. Draining that handler is what closes the gap: the loopers flag alone
covers it only once it has sent some broadcast before (`BroadcastLoopers`
registers loopers lazily), which on a freshly booted guest it may not have.
Both commands are in that release's source. `flutter drive`'s own reinstall
(it always reinstalls) is a REPLACE, as is any install over an installed
package, and the overlay manager ignores a replace for a package that neither
declares nor is targeted by an overlay. So a replace takes no barrier, and a
sound lane never reds on a wait that could not have mattered.
What the barrier cannot reach are the in-process hops after hand-over
(FgThread, the overlay manager's thread, FgThread again) — a margin of
everything before the drive's launch, not a barrier. A queue that does not
drain within `INSTALL_BARRIER_SECS` (120 s, a library constant no lane can
tighten), a device that cannot run the barrier, and a failed install each fail
the lane by name rather than driving into the race.

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

Two repo-guards steps keep it that way. `app-install-lib.sh --self-test` pins
the order, the handler drain and the loopers flag, the bound, the check that a
fresh install landed, the fail-closed paths and the no-barrier-on-a-replace
rule against a stub device. `app-install-lib.sh
--check-installs` fails if any lane installs the app another way, redefines
those functions, or talks to adb and launches the app with `flutter drive`,
`flutter test` or `flutter run` without also installing through them — so a new
lane written the ordinary way cannot miss the barrier.

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

## What these lanes do NOT cover

The iOS simulator keeps the app alive and the VM-service attached, so it does
**not** reproduce real-device background **suspension**. A "background execution
stops" bug will not surface here — that class needs a physical device, which is
out of scope for GitHub-hosted runners.

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
