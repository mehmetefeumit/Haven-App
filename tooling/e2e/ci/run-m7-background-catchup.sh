#!/usr/bin/env bash
#
# M7-E runtime-proof orchestrator for the `e2e-m7-background` CI lane
# (docs/M7E_GO_LIVE_PLAN.md D6). Proves the Android WorkManager background
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
#   M7_MARKER_TIMEOUT       marker poll bound in s (default 120).
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
readonly MARKER_TIMEOUT="${M7_MARKER_TIMEOUT:-120}"
readonly REQUIRE_DECRYPT="${M7_REQUIRE_DECRYPT:-0}"

# VERBATIM worker markers (background_catchup_worker.dart). em-dash is U+2014.
readonly MARK_BOOTSTRAP_OK='[CatchupWorker] bootstrap ok'
readonly MARK_SWEEP_COMPLETE='[CatchupWorker] sweep complete:'
readonly MARK_PENDING_WIPE='[CatchupWorker] wake: pending-wipe marker set — no-op'
readonly MARK_CONSENT_DISABLED='[CatchupWorker] wake: consent disabled — no-op'

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
  ( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
      --no-pub \
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

  drive_target "${APK_SETUP}" "${TARGET_SETUP}" "${LOG_DIR}/drive.a.log"

  go_cold

  # Registration-now-actually-registers assert: the job MUST exist.
  # WorkManager registration → JobScheduler visibility is ASYNC and, under
  # emulator memory pressure (sqlcipher mlock ENOMEM), can lag the go_cold
  # force-stop by seconds. BOUNDED poll — not one-shot — mirroring Phase B, so a
  # slow-but-correct registration is not misread as a regression. Still fails if
  # the job never appears within the budget; the assertion is unchanged.
  local ids=""
  local deadline=$(( SECONDS + JOB_REGISTER_TIMEOUT ))
  while (( SECONDS < deadline )); do
    ids="$(discover_job_ids)"
    [[ -n "${ids// /}" ]] && break
    sleep 3
  done
  if [[ -z "${ids// /}" ]]; then
    echo "---- dumpsys jobscheduler (app slice) after ${JOB_REGISTER_TIMEOUT}s ----" >&2
    adb -s "${DEVICE}" shell dumpsys jobscheduler 2>/dev/null \
      | grep -aF "${PKG}" >&2 || true
    fail "no WorkManager JobScheduler job for ${PKG} within ${JOB_REGISTER_TIMEOUT}s of registration — regression."
  fi
  echo "[phase-a] discovered job id(s): ${ids}"

  start_logcat "${LOG_DIR}/logcat.a.log"
  force_run_all "${ids}"

  if ! wait_for_marker "${LOG_DIR}/logcat.a.log" "${MARK_BOOTSTRAP_OK}" "${MARKER_TIMEOUT}"; then
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

  # A6: WorkManager re-schedules via its RescheduleReceiver + Room DB seconds-to-
  # tens-of-seconds after boot — BOUNDED poll, not one-shot.
  local ids=""
  local deadline=$(( SECONDS + JOB_REARM_TIMEOUT ))
  while (( SECONDS < deadline )); do
    ids="$(discover_job_ids)"
    [[ -n "${ids// /}" ]] && break
    sleep 3
  done
  if [[ -z "${ids// /}" ]]; then
    echo "---- dumpsys jobscheduler (app slice) ----" >&2
    adb -s "${DEVICE}" shell dumpsys jobscheduler 2>/dev/null | grep -aF "${PKG}" >&2 || true
    fail "WorkManager job did not re-appear within ${JOB_REARM_TIMEOUT}s after reboot (persistence regression)."
  fi
  echo "[phase-b] job re-scheduled after reboot: ${ids}"

  assert_reboot_receiver_resolvable

  start_logcat "${LOG_DIR}/logcat.b.log"
  force_run_all "${ids}"
  if ! wait_for_marker "${LOG_DIR}/logcat.b.log" "${MARK_BOOTSTRAP_OK}" "${MARKER_TIMEOUT}" \
     || ! wait_for_marker "${LOG_DIR}/logcat.b.log" "${MARK_SWEEP_COMPLETE}" "${MARKER_TIMEOUT}"; then
    tail -60 "${LOG_DIR}/logcat.b.log" >&2 || true
    fail "post-reboot cold wake did not complete (missing bootstrap ok / sweep complete)."
  fi
  echo "[phase-b] PASS: post-reboot cold wake booted + swept end-to-end."
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
  drive_target "${apk}" "${target}" "${LOG_DIR}/drive.${tag}.log"
  go_cold

  # Same async-registration race as Phase A — bounded poll, not one-shot.
  local ids=""
  local deadline=$(( SECONDS + JOB_REGISTER_TIMEOUT ))
  while (( SECONDS < deadline )); do
    ids="$(discover_job_ids)"
    [[ -n "${ids// /}" ]] && break
    sleep 3
  done
  [[ -z "${ids// /}" ]] && fail "phase ${name}: no registered job to force-run within ${JOB_REGISTER_TIMEOUT}s."
  echo "[phase-${tag}] job id(s): ${ids}"

  # Baseline strfry activity AFTER am kill (drive process dead), BEFORE force-run.
  local conn0 lines0
  conn0="$(strfry_conn_count)"
  lines0="$(strfry_line_count)"

  start_logcat "${LOG_DIR}/logcat.${tag}.log"
  force_run_all "${ids}"

  if ! wait_for_marker "${LOG_DIR}/logcat.${tag}.log" "${marker}" "${MARKER_TIMEOUT}"; then
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
