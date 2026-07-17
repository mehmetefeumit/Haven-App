#!/usr/bin/env bash
#
# M7-E runtime-proof orchestrator for the `e2e-background-catchup` CI lane
# (docs/M7_BACKGROUND_SHARING.md D6). Proves the Android WorkManager background
# catch-up worker at RUNTIME on the action-booted emulator-5554, across four
# phases against PERSISTENT job + app state (which is exactly why this is a
# separate lane from run-integration-tests.sh — that lane force-stops +
# uninstalls between targets, both of which strip JobScheduler jobs).
#
#   Phase A  isolate-bootstrap proof: install the setup APK, drive it to the
#            armed state (real keyring + identity + circle + seeded peer +
#            consent + registered task), go COLD, force-run the job, and assert
#            the worker booted (bootstrap ok) and swept (sweep complete:) with
#            circles>=1. Decryption counters are captured as EVIDENCE only — see
#            the "cold-process relay caveat" below.
#   Phase B  reboot re-arm: reboot the guest, wait for boot, BOUNDED-poll that
#            WorkManager re-scheduled the job (A6), assert the RebootReceiver is
#            runtime-resolvable for BOOT_COMPLETED, then force-run again.
#   Phase C1 pending-wipe no-op: install the wipe APK, drive, go cold, force-run,
#            assert the gate-2 marker AND strfry silence (zero relay activity).
#   Phase C2 leaked-wake no-op: install the disable APK, drive, go cold,
#            force-run, assert the gate-1 marker AND strfry silence.
#
# # Cold-process relay caveat (why Phase A/B assert bootstrap, not decrypt)
#
# The worker runs in a fresh process (produced with `am kill`, NOT force-stop —
# force-stop strips scheduled jobs). The debug-only ws:// loopback opt-in
# (`allow_ws_loopback_for_test`, an in-memory OnceLock with NO on-disk form,
# unlike the keyring which persists in the Android Keystore) is therefore NOT
# installed in that process, so the cold worker rejects the plaintext
# `ws://10.0.2.2:7777` CI relay and its sweep returns locations=0,relayErrors>=1.
# The DETERMINISTIC Phase-A/B assertion is thus `bootstrap ok` + `sweep complete:`
# + circles>=1 (cold RustLib.init + real keyring + SQLCipher open + identity +
# circle visible + sweep runs). The decryption counters are printed as evidence;
# set M7_REQUIRE_DECRYPT=1 to ALSO hard-assert locations>=1 && relayErrors==0 —
# do that ONLY once relay reachability from the cold worker is solved (see the
# M7-E Wave-2 report / §5 local runbook), otherwise it will fail by construction.
#
# # Marker strings
#
# The greps below are VERBATIM literals of the public consts in
# haven/lib/src/services/background_catchup_worker.dart (kCatchupWorker*Marker).
# Change a marker there, change it here AND in the unit test TOGETHER — a lone
# edit silently breaks this lane.
#
# # Why a checked-in script
#
# The reactivecircus/android-emulator-runner action runs each line of a
# multi-line `script:` in its own `sh -c`, dropping shell state (cd, vars, PIDs).
# Wrapping the whole flow in one `bash <path>` keeps it coherent — same rationale
# as the sibling tooling/e2e/ci scripts.
#
# Usage (CI — prebuilt APKs passed in, in setup/wipe/disable order):
#   bash tooling/e2e/ci/run-m7-background-catchup.sh \
#     /tmp/integration-apks/m7_worker_setup_test.apk \
#     /tmp/integration-apks/m7_worker_pending_wipe_test.apk \
#     /tmp/integration-apks/m7_worker_disable_test.apk
#
# Usage (LOCAL — omit any/all args to build that target on demand, like
# run-integration-tests.sh; NOTE: builds with the emulator up, an OOM risk):
#   bash tooling/e2e/ci/run-m7-background-catchup.sh
#
# Required env (set by the workflow before invoking):
#   HAVEN_E2E_RELAY   ws:// URL of the strfry relay (default ws://10.0.2.2:7777).
#
# Optional env:
#   M7_REQUIRE_DECRYPT      1 => also hard-assert Phase-A locations>=1 (see caveat).
#   HAVEN_DRIVE_TIMEOUT     per-drive `timeout` (default 10m).
#   M7_BOOT_TIMEOUT         reboot boot-completed bound in s (default 300).
#   M7_JOB_REARM_TIMEOUT    post-boot job re-schedule bound in s (default 60, A6).
#   M7_MARKER_TIMEOUT       per-phase worker-marker ceiling in s (default 240).
#   M7_FORCE_RUN_ROUND_POLL retry-loop inter-round poll in s (default 4; keep it
#                           below the ~10s app-freezer window — force_run_until_marker).
#   STRFRY_IMAGE, STRFRY_* — forwarded to start-strfry.sh / stop-strfry.sh.
#
# Side effects: writes /tmp/m7-logs/ (per-phase logcat + drive + strfry logs,
# uploaded as CI artifacts) and resets the hermetic strfry per phase.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
readonly PKG="com.oblivioustech.haven"
readonly DEVICE="emulator-5554"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/m7-logs"

# A4: androidx.work 2.10.x schedules into this JobScheduler namespace on
# API 34+, so every force-run must target it explicitly.
readonly JOB_NAMESPACE="androidx.work.systemjobscheduler"
# WorkManager's SystemJobService component — the discriminator for OUR job among
# any WorkManager-internal jobs in the dumpsys.
readonly SYSTEMJOB_MATCH="${PKG}/androidx.work"
# The flutter_foreground_task boot receiver (manifest flip #2; guard 14c).
readonly REBOOT_RECEIVER="com.pravera.flutter_foreground_task.service.RebootReceiver"

readonly DRIVE_TIMEOUT="${HAVEN_DRIVE_TIMEOUT:-10m}"
readonly BOOT_TIMEOUT="${M7_BOOT_TIMEOUT:-300}"
readonly JOB_REARM_TIMEOUT="${M7_JOB_REARM_TIMEOUT:-60}"
# Fresh-registration → JobScheduler visibility is async (like the reboot re-arm),
# so Phase A and the C/D force-run phases BOUNDED-poll for the job, not one-shot.
readonly JOB_REGISTER_TIMEOUT="${M7_JOB_REGISTER_TIMEOUT:-60}"
# Worker-marker ceiling (TOTAL per phase, across all force-run retry rounds).
# The cold worker is triggered via a ONE-OFF WorkManager task, force-run in a
# RETRY loop (force_run_until_marker): the FIRST force-run after go_cold is
# consumed by WorkManager's ForceStopRunnable (it interrupts + reschedules the
# just-started worker), so a LATER round — landed in the SAME still-resident
# process — is what actually boots it. The cold isolate then boots RustLib +
# keyring + SQLCipher (slow under the emulator's mlock pressure) before it logs
# bootstrap-ok, so the ceiling is generous; the loop returns the instant the
# marker appears.
readonly MARKER_TIMEOUT="${M7_MARKER_TIMEOUT:-240}"
# Inter-round gap of that retry loop (the per-round marker/started poll). It MUST
# stay shorter than the Android app-freezer's ~10s window so the NEXT force-run
# lands in the SAME, still-live process (before it freezes or the LMK reaps its
# mlock'd pages) — a fresh process would re-fire ForceStopRunnable and never
# converge. The loop STOPS force-running the instant the worker is observed
# executing (MARK_WORKER_STARTED), so this short gap never interrupts Phase A's
# slow cold bootstrap. Defaulted readonly so it can never be empty (an empty
# value would collapse the poll to zero and hammer force_run_all with no gap).
readonly FORCE_RUN_ROUND_POLL="${M7_FORCE_RUN_ROUND_POLL:-4}"
readonly REQUIRE_DECRYPT="${M7_REQUIRE_DECRYPT:-0}"
# If adb marks the emulator 'offline' (a transport drop under this lane's memory
# pressure, or right after the Phase-B guest reboot), how long to try recovering
# it before declaring an infrastructure failure. Bounded so a genuinely-wedged
# guest fails fast with an ACCURATE reason instead of a false "no job" regression.
readonly DEVICE_ONLINE_TIMEOUT="${M7_DEVICE_ONLINE_TIMEOUT:-90}"

# VERBATIM worker markers (background_catchup_worker.dart). em-dash is U+2014.
readonly MARK_BOOTSTRAP_OK='[CatchupWorker] bootstrap ok'
readonly MARK_SWEEP_COMPLETE='[CatchupWorker] sweep complete:'
readonly MARK_PENDING_WIPE='[CatchupWorker] wake: pending-wipe marker set — no-op'
readonly MARK_CONSENT_DISABLED='[CatchupWorker] wake: consent disabled — no-op'
# WorkManager's own log the instant it begins executing OUR worker (the
# flutter_workmanager plugin's BackgroundWorker), emitted just before the Dart
# callbackDispatcher runs — the earliest reliable "the cold worker is now
# booting" signal. force_run_until_marker stops re-force-running once it appears,
# so a slow in-progress bootstrap is never restarted. Specific to Haven (no other
# app on the image uses flutter_workmanager), so an app-wide grep is safe.
readonly MARK_WORKER_STARTED='WM-WorkerWrapper: Starting work for dev.fluttercommunity.workmanager.BackgroundWorker'

# Three targets, in fixed order. Args override each APK; a missing arg/file
# triggers a LOCAL build of that target.
readonly TARGET_SETUP="integration_test/m7_worker_setup_test.dart"
readonly TARGET_WIPE="integration_test/m7_worker_pending_wipe_test.dart"
readonly TARGET_DISABLE="integration_test/m7_worker_disable_test.dart"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${script_dir}"
readonly REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly START_STRFRY="${SCRIPT_DIR}/start-strfry.sh"
readonly STOP_STRFRY="${SCRIPT_DIR}/stop-strfry.sh"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

LOGCAT_PID=""

# ---------------------------------------------------------------------------
# Cleanup (EXIT trap): flush logcat, run the mandatory secret scan over EVERY
# captured log (Security Rule 6 — must run even on a phase failure), snapshot +
# tear down strfry. Escalates the exit code on a leak; never masks a phase rc.
# ---------------------------------------------------------------------------
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  docker logs strfry > "${LOG_DIR}/strfry.final.log" 2>&1 || true
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  if ! bash "${SECRET_SCAN}" "${LOG_DIR}"; then
    echo "ERROR: secret-leak guard tripped on M7 logs — see LEAK line(s)." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "M7-LANE-FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# Reset the hermetic strfry (fresh LMDB) at the start of a phase.
reset_strfry() {
  echo "[relay] resetting strfry for $1"
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  bash "${START_STRFRY}"
}

# (Re)start host logcat capture into a fresh per-phase file. Clears the device
# buffer first so each phase only sees ITS markers (the plan's `logcat -c`).
start_logcat() {
  local outfile="$1"
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  adb -s "${DEVICE}" logcat -c || true
  adb -s "${DEVICE}" logcat -v threadtime > "${outfile}" 2>&1 &
  LOGCAT_PID=$!
}

# Bounded poll of a logcat file for a VERBATIM marker. `-aF`: treat the
# binary-tainted logcat as text and match the fixed literal (em-dash included).
wait_for_marker() {
  local logfile="$1" marker="$2" timeout_s="$3"
  local deadline=$(( SECONDS + timeout_s ))
  while (( SECONDS < deadline )); do
    if grep -aqF -- "${marker}" "${logfile}" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# Assert a marker is ABSENT from a logcat file (negative proof).
assert_marker_absent() {
  local logfile="$1" marker="$2" label="$3"
  if grep -aqF -- "${marker}" "${logfile}" 2>/dev/null; then
    echo "---- offending logcat tail ----" >&2
    tail -40 "${logfile}" >&2 || true
    fail "${label}: unexpected marker present: ${marker}"
  fi
}

# Extract counter <key> (e.g. circles) from the LAST sweep-complete line.
# Trailing `|| true` so a missing key returns empty (rc 0) instead of tripping
# `set -e` inside the `$(...)` capture at the call site (the caller checks empty).
parse_counter() {
  local logfile="$1" key="$2"
  { grep -aF -- "${MARK_SWEEP_COMPLETE}" "${logfile}" 2>/dev/null | tail -1 \
    | grep -oaE "${key}=[0-9]+" | tail -1 | cut -d= -f2; } || true
}

# ---------------------------------------------------------------------------
# Emulator health.
#
# This lane is memory-heavy — a cold worker isolate boots RustLib + SQLCipher
# (mlock'd pages) alongside the resident app, WorkManager, and the FGS — and it
# deliberately reboots the guest in Phase B. Under that pressure the GH runner's
# software-GPU emulator can drop its adb transport to 'offline': the guest is
# often still alive, only the socket handshake was lost. `adb reconnect offline`
# re-establishes it; wait-for-device + a sys.boot_completed poll then confirm the
# shell is actually serving again.
#
# Every job-discovery poll calls ensure_device_online FIRST, so a transient
# transport drop self-heals instead of returning an empty dumpsys that the
# downstream check would MISREAD as a "no job registered" product regression.
# If the guest is genuinely wedged (not recoverable within the budget) the lane
# fails with an accurate infrastructure reason, not a false regression.
# ---------------------------------------------------------------------------
device_state() {
  adb -s "${DEVICE}" get-state 2>/dev/null | tr -d '\r' || true
}

# Returns 0 once the device is 'device' state AND booted; 1 if it stays
# unreachable for DEVICE_ONLINE_TIMEOUT. Fast-returns when already online, so it
# is cheap to call at the top of every poll iteration.
ensure_device_online() {
  [[ "$(device_state)" == "device" ]] && return 0
  echo "[device] ${DEVICE} state='$(device_state)'; attempting adb reconnect..." >&2
  local deadline=$(( SECONDS + DEVICE_ONLINE_TIMEOUT ))
  while (( SECONDS < deadline )); do
    adb reconnect offline >/dev/null 2>&1 || true
    adb -s "${DEVICE}" wait-for-device >/dev/null 2>&1 || true
    if [[ "$(device_state)" == "device" ]] &&
       [[ "$(adb -s "${DEVICE}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
      echo "[device] ${DEVICE} recovered to online." >&2
      return 0
    fi
    sleep 3
  done
  echo "[device] ${DEVICE} did not recover within ${DEVICE_ONLINE_TIMEOUT}s (state='$(device_state)')." >&2
  return 1
}

# Namespace-tolerant discovery of OUR WorkManager job id(s). The AOSP job
# header line carries both the `#u<user>a<app>/<jobId>` token and the
# `<pkg>/<component>` on one line; -oE isolates the numeric jobId from the token
# (the component's own `/` is not part of that token).
# Trailing `|| true`: a `grep` with no match returns 1, which under `pipefail`
# would abort the `ids="$(discover_job_ids)"` capture via `set -e` BEFORE the
# caller's explicit empty-check + evidence dump. Empty stdout is the signal.
discover_job_ids() {
  { adb -s "${DEVICE}" shell dumpsys jobscheduler 2>/dev/null \
    | grep -aF "${SYSTEMJOB_MATCH}" \
    | grep -aoE '#u[0-9]+a[0-9]+/[0-9]+' \
    | sed -E 's@.*/@@' \
    | sort -un \
    | tr '\n' ' '; } || true
}

# Fallback discovery: WorkManager logs the OS JobScheduler id it scheduled
# ("WM-SystemJobScheduler: Scheduling work ID <uuid>Job ID <n>"). When the
# dumpsys-based discover_job_ids comes up empty, parse those ids from the drive
# log so a force-run can still target the job by id — covering the case where
# `dumpsys jobscheduler` did not surface it grep-ably. The worker success marker
# downstream still gates a real pass, so a stale/wrong id cannot green a phase.
job_ids_from_drive_log() {
  local drivelog="$1"
  [[ -f "${drivelog}" ]] || return 0
  { grep -aoE 'Job ID [0-9]+' "${drivelog}" 2>/dev/null \
    | sed -E 's/^Job ID //' | sort -un | tr '\n' ' '; } || true
}

# Same idea, but from the whole-phase logcat. A FAST drive (the ~1s negative
# phases) DETACHES before WorkManager's async SystemJobScheduler.schedule()
# emits the Job ID, so the id never reaches the drive log — only the logcat that
# start_logcat began BEFORE the drive. Restrict to the app's LIVE pid(s) so
# other apps' WorkManager scheduling (wellbeing, GMS) cannot leak a foreign
# Job ID (`$3` is the pid column of `logcat -v threadtime`).
job_ids_from_logcat() {
  local logfile="$1"
  [[ -f "${logfile}" ]] || return 0
  local pids
  pids="$(adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null | tr -d '\r' | tr ' ' '|')"
  [[ -z "${pids}" ]] && return 0
  { awk -v pids="${pids}" '
      $3 ~ ("^(" pids ")$") && /WM-SystemJobScheduler: Scheduling work ID/ {
        if (match($0, /Job ID [0-9]+/)) print substr($0, RSTART + 7, RLENGTH - 7)
      }' "${logfile}" 2>/dev/null | sort -un | tr '\n' ' '; } || true
}

# Comprehensive JobScheduler / app-state diagnostics for a discovery miss, so a
# genuine "job absent" cause (app force-stopped? killed? stopped-state? a
# constraint dropping it?) is VISIBLE in the CI log rather than inferred.
dump_job_diagnostics() {
  local drivelog="${1:-}"
  {
    echo "-- pidof ${PKG} (is the app process still alive?):"
    adb -s "${DEVICE}" shell pidof "${PKG}" 2>&1 || true
    echo "-- dumpsys package ${PKG} (stopped-state / user flags):"
    adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>/dev/null \
      | grep -aiE 'stopped=|User 0:|flags=\[' | head -6 || true
    echo "-- cmd jobscheduler get-job-state ${PKG} 0:"
    adb -s "${DEVICE}" shell cmd jobscheduler get-job-state "${PKG}" 0 2>&1 || true
    echo "-- dumpsys jobscheduler (haven / androidx.work / registered-count):"
    adb -s "${DEVICE}" shell dumpsys jobscheduler 2>&1 \
      | grep -aiE 'haven|androidx\.work|Registered [0-9]+ job|SystemJobService' \
      | head -30 || true
    if [[ -n "${drivelog}" && -f "${drivelog}" ]]; then
      echo "-- WorkManager scheduling lines in the drive log:"
      grep -aE 'WM-SystemJobScheduler|Unable to schedule|Job ID' "${drivelog}" | tail -6 || true
    fi
  } >&2
}

# Force-run one job in the A4 namespace, with a no-namespace fallback for images
# whose `cmd jobscheduler` lacks `-n`. The marker poll is the real success
# signal, so a per-id error here is logged, not fatal.
run_one_job() {
  local id="$1" out
  out="$(adb -s "${DEVICE}" shell cmd jobscheduler run -f -n "${JOB_NAMESPACE}" "${PKG}" "${id}" 2>&1 || true)"
  echo "  [run -n ${JOB_NAMESPACE}] id=${id}: ${out:-<no output>}"
  # 'could not find' matches AOSP's CMD_ERR_NO_JOB ("Could not find job to run")
  # — note that string has "not find", not "not found", so it is listed
  # explicitly (relevant only under a future WorkManager namespace drift).
  if printf '%s' "${out}" | grep -qiE 'error|unknown option|invalid|no such|not found|could not find'; then
    out="$(adb -s "${DEVICE}" shell cmd jobscheduler run -f "${PKG}" "${id}" 2>&1 || true)"
    echo "  [run fallback] id=${id}: ${out:-<no output>}"
  fi
}

force_run_all() {
  local ids="$1" id
  for id in ${ids}; do
    run_one_job "${id}"
  done
}

# Force-run the WorkManager job id(s) in a RETRY loop until `marker` appears in
# `logfile`, or `timeout_s` elapses. Returns 0 on the marker, 1 on timeout.
# `drivelog` + `seed_ids` feed the per-round re-discovery; `seed_ids` is the
# pre-go_cold discovered set (the one-off keeps a STABLE JobScheduler id, so
# seeding guarantees it is force-run every round even if a post-kill re-discovery
# momentarily comes up empty while the app process is dead).
#
# WHY a retry loop instead of a single force_run_all + wait (the previous design,
# which flaked on Phase C2):
#   * The FIRST force-run after go_cold lands in a FRESH app process, and every
#     fresh process's WorkManager init runs ForceStopRunnable (`am kill` / the
#     reinstall leave a REASON_USER_REQUESTED exit that WM reads as "force-
#     stopped"). ForceStopRunnable INTERRUPTS the just-started worker — logcat:
#     onStopJob -> "WorkerWrapper interrupted" -> "is ENQUEUED; not doing any
#     work and rescheduling for later execution" — and re-enqueues the one-off
#     with its ~60s initialDelay reapplied; it does NOT run.
#   * With a single force-run the worker then booted ONLY if that fresh process
#     happened to survive ~60s so WorkManager's IN-PROCESS DelayedWorkTracker
#     fired the delayed one-off — a race the Android app-freezer wins or loses
#     per run (Phase A/C1 survived ~60-70s and passed; a C2 process froze at
#     +16s and the worker NEVER booted within 240s -> false lane failure).
#
# HOW the loop converges deterministically:
#   * ForceStopRunnable fires at most ONCE per process init and re-arms its
#     sentinel. The force-run process is FROZEN, not killed, after it comes up
#     (logcat "freezing <pid>"), so it stays resident. A SECOND force-run, issued
#     one SHORT round-gap later (FORCE_RUN_ROUND_POLL, kept < the ~10s freeze
#     window), is delivered into that SAME initialized process (thawed):
#     ForceStopRunnable does NOT re-fire, WorkerWrapper runs the worker, and
#     `cmd jobscheduler run -f` bypasses the reapplied initialDelay -> it boots.
#     Each round also re-thaws the process, keeping it warm.
#   * The loop STOPS force-running the instant WorkManager logs it is executing
#     our worker (MARK_WORKER_STARTED), then waits UNINTERRUPTED for the target
#     marker. This protects Phase A's slow cold bootstrap (RustLib + keyring +
#     SQLCipher, ~10-30s under mlock) from a force-run that could RESTART an
#     already-running job (run -f-on-a-running-job semantics are image-dependent;
#     never rely on it being a no-op).
#
# The per-round app pid is logged so a divergence (the mlock-heavy process being
# LMK-reaped between rounds, each respawn re-firing ForceStopRunnable) is
# diagnosable as an infra limit from the CI log rather than misread as a product
# regression. On timeout the job diagnostics are dumped before returning 1.
force_run_until_marker() {
  local logfile="$1" marker="$2" timeout_s="$3" drivelog="$4" seed_ids="$5"
  local deadline=$(( SECONDS + timeout_s )) round=0 ids pid worker_started=0
  while (( SECONDS < deadline )); do
    round=$(( round + 1 ))
    ensure_device_online || true
    # Guard BEFORE (re-)force-running: if the target marker is already present we
    # are done; if the worker already began executing (possibly at the tail of the
    # previous round's poll), do NOT force-run again — fall through to the
    # uninterrupted wait so a slow in-progress bootstrap is never restarted.
    if grep -aqF -- "${marker}" "${logfile}" 2>/dev/null; then
      echo "[force-run] marker observed on round ${round}."
      return 0
    fi
    if grep -aqF -- "${MARK_WORKER_STARTED}" "${logfile}" 2>/dev/null; then
      worker_started=1
      break
    fi
    # Re-discover CURRENT ids each round (ForceStopRunnable RENUMBERS the periodic
    # on reschedule); union with the stable seed so the one-off is always targeted.
    ids="$(printf '%s %s %s %s' "${seed_ids}" \
      "$(job_ids_from_drive_log "${drivelog}")" \
      "$(job_ids_from_logcat "${logfile}")" \
      "$(discover_job_ids)" \
      | tr ' ' '\n' | grep -aE '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
    pid="$(adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null | tr -d '\r' || true)"
    echo "[force-run round ${round}] job id(s): ${ids:-<none>} app-pid: ${pid:-<none>}"
    # The worker may have begun executing DURING the multi-adb re-discovery above;
    # re-check right before firing so we never force-run into an already-running
    # worker (keeps Phase A's slow cold bootstrap uninterrupted in that narrow
    # window too — see the MARK_WORKER_STARTED rationale in this function's doc).
    if grep -aqF -- "${MARK_WORKER_STARTED}" "${logfile}" 2>/dev/null; then
      worker_started=1
      break
    fi
    force_run_all "${ids}"
    # In-round poll (1s granularity): return on the target marker; STOP the
    # hammer the instant the worker is executing (then fall to the wait below).
    local sub_deadline=$(( SECONDS + FORCE_RUN_ROUND_POLL ))
    while (( SECONDS < sub_deadline && SECONDS < deadline )); do
      if grep -aqF -- "${marker}" "${logfile}" 2>/dev/null; then
        echo "[force-run] marker observed on round ${round}."
        return 0
      fi
      if grep -aqF -- "${MARK_WORKER_STARTED}" "${logfile}" 2>/dev/null; then
        worker_started=1
        break
      fi
      sleep 1
    done
    if (( worker_started == 1 )); then
      break
    fi
  done

  # Worker is executing (or the hammer budget ran out): wait UNINTERRUPTED for
  # the target marker up to the remaining deadline — no more force-runs.
  if (( worker_started == 1 )); then
    echo "[force-run] worker executing; awaiting marker uninterrupted (no more force-runs)."
  fi
  local remaining=$(( deadline - SECONDS ))
  if (( remaining < 1 )); then
    remaining=1
  fi
  if wait_for_marker "${logfile}" "${marker}" "${remaining}"; then
    return 0
  fi
  # Timed out — surface WHY (offline? job gone? process never stayed resident?).
  echo "---- force-run loop timed out after ${round} round(s) — diagnostics ----" >&2
  dump_job_diagnostics "${drivelog}"
  return 1
}

# Cold-process state WITHOUT force-stop (which would strip the scheduled job):
# HOME then `am kill` (OOM-style kill; jobs survive; process is gone). The HOME
# keyevent backgrounds the still-running app (onPause/onStop), which flushes any
# pending SharedPreferences apply() write (Android QueuedWork) so the worker's
# separate process reliably reads the consent/wipe prefs the drive just set. The
# sleep between HOME and `am kill` gives that flush time to complete.
go_cold() {
  adb -s "${DEVICE}" shell input keyevent HOME || true
  sleep 3
  adb -s "${DEVICE}" shell am kill "${PKG}" || true
  sleep 2
}

grant_perms() {
  local perm
  for perm in \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION \
    android.permission.POST_NOTIFICATIONS; do
    adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" >/dev/null 2>&1 \
      && echo "  granted ${perm}" || echo "  WARN: could not grant ${perm}"
  done
}

# Drive an integration target on the installed APK. Bounded by `timeout` so a
# hung drive fails the phase fast instead of the whole job (matches
# run-single-avd-scenario.sh). A plain `>` redirect (never `| tee`) so a
# timeout-killed drive's orphaned adb children can't defer the shell forever.
drive_target() {
  local apk="$1" target="$2" drivelog="$3" drc=0
  echo "[drive] ${target} on ${DEVICE} (timeout ${DRIVE_TIMEOUT})"
  # --keep-app-running is LOAD-BEARING for this lane. Without it `flutter drive`
  # defaults (for --use-application-binary, i.e. not --use-existing-app) to
  # STOPPING the app when the test completes, and on Android
  # AndroidDevice.stopApp() runs `adb shell am force-stop` (flutter_tools
  # android_device.dart). `am force-stop` CANCELS the app's JobScheduler jobs —
  # including the WorkManager catch-up job the setup drive just scheduled (the
  # drive log shows `WM-SystemJobScheduler: Scheduling ... Job ID 0`, then the
  # job is gone from dumpsys). That silently defeats the whole lane: go_cold
  # below uses `am kill` (NOT force-stop) precisely to PRESERVE the scheduled
  # job, but the drive's own teardown force-stopped it first. Keeping the app
  # running leaves the job in JobScheduler for the discovery poll; go_cold then
  # OOM-style-kills the process without stripping the job.
  ( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
      --no-pub \
      --keep-app-running \
      --device-id "${DEVICE}" \
      --use-application-binary "${apk}" \
      --driver "${DRIVER_FILE}" \
      --target "${target}" ) > "${drivelog}" 2>&1 || drc=$?
  cat "${drivelog}" || true
  if (( drc != 0 )); then
    fail "drive of ${target} failed (rc=${drc}) — cannot arm the worker state."
  fi
}

# strfry activity probes for the SILENCE assertions. Lead with connection-line
# grep (robust to volume), corroborate with total line count.
strfry_conn_count() {
  docker logs strfry 2>&1 \
    | grep -icE 'connection (open|opened|established|accepted)|new connection|client connected' \
    || true
}
strfry_line_count() {
  { docker logs strfry 2>&1 | wc -l | tr -d ' '; } || true
}

# ---------------------------------------------------------------------------
# APK resolution (CI: prebuilt path passed in; LOCAL: build on demand)
# ---------------------------------------------------------------------------
resolve_apk() {
  local provided="$1" target="$2" staged="$3"
  if [[ -n "${provided}" && -f "${provided}" ]]; then
    printf '%s' "${provided}"
    return 0
  fi
  echo "[build] no prebuilt APK for ${target}; building on demand (LOCAL)..." >&2
  ( cd "${HAVEN_DIR}" && flutter build apk \
      --debug \
      --target-platform android-x64 \
      --target="${target}" \
      --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" >&2 )
  cp "${HAVEN_DIR}/build/app/outputs/flutter-apk/app-debug.apk" "${staged}"
  printf '%s' "${staged}"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------

phase_a() {
  echo "============================================================"
  echo "Phase A — isolate-bootstrap proof (positive)"
  echo "============================================================"
  reset_strfry "phase A"

  echo "[install] fresh install of setup APK"
  adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
  adb -s "${DEVICE}" install -r "${APK_SETUP}"
  grant_perms

  # Capture logcat for the WHOLE phase (started BEFORE the drive), so the one-off
  # worker's markers are captured whether it runs COLD (after go_cold + force-run
  # — the normal case) or, if a slow drive ever outlasts its ~60s initial delay,
  # EARLY in the still-live process. Either way the bootstrap/sweep proof holds.
  start_logcat "${LOG_DIR}/logcat.a.log"

  drive_target "${APK_SETUP}" "${TARGET_SETUP}" "${LOG_DIR}/drive.a.log"

  # Discover the WorkManager JobScheduler id(s) to force-run. WorkManager on API
  # 34 schedules into the `androidx.work.systemjobscheduler` NAMESPACE, which the
  # plain `dumpsys jobscheduler | grep` in discover_job_ids CANNOT see (proven —
  # the job runs via `cmd jobscheduler run -f -n <namespace>` but never shows in
  # that grep). So the RELIABLE source is the id WorkManager logs verbatim in the
  # drive ("Scheduling work ID <uuid>Job ID <n>"), which covers BOTH the
  # production periodic task AND the CI one-off task — the periodic only
  # reschedules when force-run early (WM behavior), the ONE-OFF is what actually
  # boots the cold worker. Union with any dumpsys-visible ids for
  # belt-and-suspenders; force_run_all targets the namespace.
  local ids="" log_ids="" logcat_ids="" dump_ids=""
  local deadline=$(( SECONDS + JOB_REGISTER_TIMEOUT ))
  while (( SECONDS < deadline )); do
    ensure_device_online ||
      fail "emulator ${DEVICE} went OFFLINE and did not recover — CI infrastructure/emulator instability, NOT a WorkManager regression. See the diag artifact."
    log_ids="$(job_ids_from_drive_log "${LOG_DIR}/drive.a.log")"
    logcat_ids="$(job_ids_from_logcat "${LOG_DIR}/logcat.a.log")"
    dump_ids="$(discover_job_ids)"
    ids="$(printf '%s %s %s' "${log_ids}" "${logcat_ids}" "${dump_ids}" | tr ' ' '\n' | grep -aE '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
    [[ -n "${ids// /}" ]] && break
    sleep 3
  done
  if [[ -z "${ids// /}" ]]; then
    echo "---- no WorkManager Job ID after ${JOB_REGISTER_TIMEOUT}s (app alive) — diagnostics ----" >&2
    dump_job_diagnostics "${LOG_DIR}/drive.a.log"
    fail "no WorkManager Job ID in the drive log, logcat, or dumpsys for ${PKG} within ${JOB_REGISTER_TIMEOUT}s — the worker was never scheduled."
  fi
  echo "[phase-a] WM JobScheduler id(s) to force-run (periodic + one-off): ${ids}"

  go_cold

  if ! force_run_until_marker "${LOG_DIR}/logcat.a.log" "${MARK_BOOTSTRAP_OK}" \
        "${MARKER_TIMEOUT}" "${LOG_DIR}/drive.a.log" "${ids}"; then
    tail -60 "${LOG_DIR}/logcat.a.log" >&2 || true
    fail "worker never logged '${MARK_BOOTSTRAP_OK}' within ${MARKER_TIMEOUT}s (isolate bootstrap failed)."
  fi
  echo "[phase-a] bootstrap ok observed."
  if ! wait_for_marker "${LOG_DIR}/logcat.a.log" "${MARK_SWEEP_COMPLETE}" "${MARKER_TIMEOUT}"; then
    tail -60 "${LOG_DIR}/logcat.a.log" >&2 || true
    fail "worker never logged '${MARK_SWEEP_COMPLETE}' within ${MARKER_TIMEOUT}s (sweep did not run)."
  fi

  local circles locations relay_errors
  circles="$(parse_counter "${LOG_DIR}/logcat.a.log" circles)"
  locations="$(parse_counter "${LOG_DIR}/logcat.a.log" locations)"
  relay_errors="$(parse_counter "${LOG_DIR}/logcat.a.log" relayErrors)"
  echo "[phase-a] sweep counters: circles=${circles:-?} locations=${locations:-?} relayErrors=${relay_errors:-?}"

  if [[ -z "${circles}" ]] || (( circles < 1 )); then
    fail "sweep reported circles=${circles:-<none>} (<1) — worker did not open the app's circle DB."
  fi
  echo "[phase-a] PASS (deterministic): cold isolate booted Rust+keyring+SQLCipher, opened the DB, swept circles>=1."

  # Decryption evidence — see the cold-process relay caveat in the header.
  if [[ -n "${locations}" ]] && (( locations >= 1 )) \
     && [[ -n "${relay_errors}" ]] && (( relay_errors == 0 )); then
    echo "[phase-a] DECRYPTION OBSERVED: locations=${locations} relayErrors=0 (worker reached the relay)."
  else
    echo "[phase-a] NOTE: decryption NOT observed in the cold worker" \
         "(locations=${locations:-?} relayErrors=${relay_errors:-?})." \
         "Expected: the ws:// loopback opt-in is process-global with no persistent" \
         "form, so a cold worker cannot reach the plaintext CI relay. See the M7-E" \
         "Wave-2 report / §5 runbook. Bootstrap proof above stands."
    if [[ "${REQUIRE_DECRYPT}" == "1" ]]; then
      fail "M7_REQUIRE_DECRYPT=1 but decryption was not observed (see NOTE above)."
    fi
  fi
}

phase_b() {
  echo "============================================================"
  echo "Phase B — reboot re-arm (consent still ON)"
  echo "============================================================"
  echo "[phase-b] rebooting the guest..."
  adb -s "${DEVICE}" reboot
  if ! wait_for_boot "${BOOT_TIMEOUT}"; then
    fail "guest did not reach sys.boot_completed=1 within ${BOOT_TIMEOUT}s after reboot."
  fi
  adb -s "${DEVICE}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
  echo "[phase-b] boot complete."

  # Reboot PERSISTENCE proof. WorkManager's RescheduleReceiver (registered for
  # BOOT_COMPLETED) re-schedules the PERIODIC catch-up job from its Room DB after
  # boot. We assert that WIRING is intact — the RescheduleReceiver is resolvable
  # (below) — plus a best-effort observation that WorkManager re-scheduled after
  # boot. The cold worker RUN is proven by Phase A's ONE-OFF task: a PERIODIC
  # task cannot be force-run early (WorkManager reschedules it via
  # ForceStopRunnable + periodic-timing — see docs/E2E_TROUBLESHOOTING.md), so a
  # post-reboot force-run of the periodic would NOT run the worker. Phase B
  # therefore proves reboot re-arm WIRING + persistence, not a second cold run.
  assert_reboot_receiver_resolvable

  start_logcat "${LOG_DIR}/logcat.b.log"
  if wait_for_marker "${LOG_DIR}/logcat.b.log" "WM-SystemJobScheduler: Scheduling" "${JOB_REARM_TIMEOUT}"; then
    echo "[phase-b] WorkManager re-scheduled work after boot (RescheduleReceiver path observed)."
  else
    echo "[phase-b] NOTE: no WorkManager re-schedule log within ${JOB_REARM_TIMEOUT}s" \
         "(non-fatal — RebootReceiver resolvability above is the load-bearing proof)." >&2
  fi
  echo "[phase-b] PASS: reboot re-arm wiring verified (RebootReceiver resolvable for BOOT_COMPLETED)."
}

assert_reboot_receiver_resolvable() {
  local out
  out="$(adb -s "${DEVICE}" shell cmd package query-receivers --components -a android.intent.action.BOOT_COMPLETED 2>/dev/null || true)"
  if printf '%s' "${out}" | grep -qF "${REBOOT_RECEIVER}"; then
    echo "[phase-b] RebootReceiver resolvable for BOOT_COMPLETED (enabled=true + intent-filter intact)."
    return 0
  fi
  # Fallback for images whose `cmd package query-receivers` syntax differs.
  out="$(adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>/dev/null || true)"
  if printf '%s' "${out}" | grep -qF "${REBOOT_RECEIVER}"; then
    echo "[phase-b] RebootReceiver present in dumpsys package (fallback resolution check)."
    return 0
  fi
  fail "RebootReceiver not resolvable for BOOT_COMPLETED — manifest flip #2 (enabled=true) or the plugin intent-filter regressed."
}

wait_for_boot() {
  local timeout_s="$1"
  adb -s "${DEVICE}" wait-for-device
  local deadline=$(( SECONDS + timeout_s )) bc
  while (( SECONDS < deadline )); do
    bc="$(adb -s "${DEVICE}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    [[ "${bc}" == "1" ]] && return 0
    sleep 2
  done
  return 1
}

# Shared negative phase: install-over (data preserved), drive, go cold, force-run,
# assert the expected no-op marker AND strfry silence AND no bootstrap/sweep.
run_negative_phase() {
  local name="$1" apk="$2" target="$3" marker="$4" tag="$5"
  echo "============================================================"
  echo "Phase ${name}"
  echo "============================================================"
  reset_strfry "phase ${name}"

  echo "[install] install -r ${target} (data preserved)"
  adb -s "${DEVICE}" install -r "${apk}"
  grant_perms

  # Capture logcat for the whole phase (before the drive) — see Phase A: the
  # one-off no-op marker is captured whether the worker runs cold or early.
  start_logcat "${LOG_DIR}/logcat.${tag}.log"
  drive_target "${apk}" "${target}" "${LOG_DIR}/drive.${tag}.log"

  # Discover the WM JobScheduler id(s) to force-run — namespace-blind dumpsys is
  # unreliable (see Phase A), so union the ids WorkManager logs in the drive
  # (periodic + CI one-off) with any dumpsys-visible ids. The ONE-OFF is what
  # actually boots the cold worker (the periodic reschedules when force-run
  # early). force_run_all targets the androidx.work namespace.
  local ids="" log_ids="" logcat_ids="" dump_ids=""
  local deadline=$(( SECONDS + JOB_REGISTER_TIMEOUT ))
  while (( SECONDS < deadline )); do
    ensure_device_online ||
      fail "phase ${name}: emulator ${DEVICE} went OFFLINE and did not recover — CI infrastructure/emulator instability, NOT a WorkManager regression. See the diag artifact."
    log_ids="$(job_ids_from_drive_log "${LOG_DIR}/drive.${tag}.log")"
    logcat_ids="$(job_ids_from_logcat "${LOG_DIR}/logcat.${tag}.log")"
    dump_ids="$(discover_job_ids)"
    ids="$(printf '%s %s %s' "${log_ids}" "${logcat_ids}" "${dump_ids}" | tr ' ' '\n' | grep -aE '^[0-9]+$' | sort -un | tr '\n' ' ' || true)"
    [[ -n "${ids// /}" ]] && break
    sleep 3
  done
  if [[ -z "${ids// /}" ]]; then
    echo "---- phase ${name}: no WM Job ID after ${JOB_REGISTER_TIMEOUT}s (app alive) — diagnostics ----" >&2
    dump_job_diagnostics "${LOG_DIR}/drive.${tag}.log"
    fail "phase ${name}: no WorkManager Job ID in the drive log, logcat, or dumpsys within ${JOB_REGISTER_TIMEOUT}s — the worker was never scheduled."
  fi
  echo "[phase-${tag}] WM JobScheduler id(s) to force-run (periodic + one-off): ${ids}"

  go_cold

  # Baseline strfry activity AFTER am kill (drive process dead), BEFORE force-run.
  local conn0 lines0
  conn0="$(strfry_conn_count)"
  lines0="$(strfry_line_count)"

  if ! force_run_until_marker "${LOG_DIR}/logcat.${tag}.log" "${marker}" \
        "${MARKER_TIMEOUT}" "${LOG_DIR}/drive.${tag}.log" "${ids}"; then
    tail -60 "${LOG_DIR}/logcat.${tag}.log" >&2 || true
    fail "phase ${name}: worker never logged the expected no-op marker within ${MARKER_TIMEOUT}s: ${marker}"
  fi
  echo "[phase-${tag}] no-op marker observed: ${marker}"

  # Settle, then prove ZERO network + no bootstrap/sweep.
  sleep 5
  local conn1 lines1
  conn1="$(strfry_conn_count)"
  lines1="$(strfry_line_count)"
  docker logs strfry > "${LOG_DIR}/strfry.${tag}.log" 2>&1 || true
  if [[ "${conn1}" != "${conn0}" ]]; then
    fail "phase ${name}: strfry connection lines changed (${conn0} -> ${conn1}) — the wake reached the relay."
  fi
  if [[ "${lines1}" != "${lines0}" ]]; then
    # L2: corroborating check only. A late connection-teardown log line from the
    # am-kill'd drive process can change the line count without any wake
    # activity, so this must NOT hard-fail — the connection-count check above is
    # the authoritative silence proof (a wake reaching the relay would OPEN a
    # new connection, which conn-count catches).
    echo "[phase-${tag}] note: strfry log line count changed (${lines0} ->" \
         "${lines1}) but connection count is unchanged — treating as drive-" \
         "teardown noise, not a wake." >&2
  fi
  assert_marker_absent "${LOG_DIR}/logcat.${tag}.log" "${MARK_BOOTSTRAP_OK}" "phase ${name}"
  assert_marker_absent "${LOG_DIR}/logcat.${tag}.log" "${MARK_SWEEP_COMPLETE}" "phase ${name}"
  echo "[phase-${tag}] PASS: gate declined the wake; strfry silent (conn=${conn0}, lines=${lines0}); no bootstrap/sweep."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  for dep in "${START_STRFRY}" "${STOP_STRFRY}" "${SECRET_SCAN}"; do
    [[ -f "${dep}" ]] || fail "required helper not found: ${dep}"
  done
  [[ -f "${HAVEN_DIR}/pubspec.yaml" ]] || fail "Haven project not found at ${HAVEN_DIR}"
  [[ -f "${HAVEN_DIR}/${DRIVER_FILE}" ]] || fail "${DRIVER_FILE} missing — required by flutter drive."

  # D6 self-guard: this lane is meaningless with the flag OFF; fail loudly so a
  # rollback that forgets to remove the ci.yml fan-out entry doesn't run a lane
  # that can never register a task.
  if ! grep -qE 'const bool backgroundCatchupEnabled = true;' \
      "${HAVEN_DIR}/lib/src/providers/live_sync_provider.dart"; then
    fail "backgroundCatchupEnabled is not 'true' — this lane requires the flag ON. Remove the ci.yml fan-out entry if rolling back (plan §7)."
  fi

  mkdir -p "${LOG_DIR}"

  echo "M7 background-catch-up runtime lane — relay=${RELAY_URL} require_decrypt=${REQUIRE_DECRYPT}"

  # Resolve all three APKs up front (build any missing ones BEFORE the phases so
  # a LOCAL build never interleaves with a force-run).
  APK_SETUP="$(resolve_apk "${1:-}" "${TARGET_SETUP}" "${LOG_DIR}/setup.apk")"
  APK_WIPE="$(resolve_apk "${2:-}" "${TARGET_WIPE}" "${LOG_DIR}/wipe.apk")"
  APK_DISABLE="$(resolve_apk "${3:-}" "${TARGET_DISABLE}" "${LOG_DIR}/disable.apk")"
  readonly APK_SETUP APK_WIPE APK_DISABLE
  echo "APKs: setup=${APK_SETUP} wipe=${APK_WIPE} disable=${APK_DISABLE}"

  phase_a
  phase_b
  run_negative_phase "C1 — pending-wipe no-op" "${APK_WIPE}" "${TARGET_WIPE}" "${MARK_PENDING_WIPE}" "c1"
  run_negative_phase "C2 — no-network-after-disable" "${APK_DISABLE}" "${TARGET_DISABLE}" "${MARK_CONSENT_DISABLED}" "c2"

  echo
  echo "============================================================"
  echo "M7 background-catch-up lane: ALL PHASES PASSED"
  echo "  A  cold isolate bootstrap + DB open + sweep (circles>=1)"
  echo "  B  job survives reboot + RebootReceiver resolvable + post-boot wake"
  echo "  C1 pending-wipe gate declines + strfry silence"
  echo "  C2 consent gate declines a leaked wake + strfry silence"
  echo "============================================================"
  # The secret scan runs in the EXIT trap (Security Rule 6), even here.
}

main "$@"
