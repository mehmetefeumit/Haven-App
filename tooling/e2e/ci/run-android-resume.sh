#!/usr/bin/env bash
# Android resume lane: background sharing comes back with NO UI launch after an
# app update, a reboot and a process kill, and posts the resume notice instead
# of a silently broken service when it may not (owner-directed 2026-11-26,
# OD-R2/OD-R3; BootResumeReceiver, ResumeRule.kt decideResume, and the Dart
# system-start gate in background_resume_gate.dart).
#
# Legs, each over the state the one before it left:
#   setup  fresh install, the setup drive (real keyring identity, a circle with
#          an accepted peer on the CI relay, sharing on, the CURRENT background
#          disclosure accepted, the service RUNNING) — "Allow all the time" is
#          NOT granted.
#   U1     `install -r` (MY_PACKAGE_REPLACED, the process killed): the resume
#          notice is posted, no service runs, nothing crashed.
#   U2     "Allow all the time" granted, `install -r` again: the service starts
#          as a SYSTEM start, passes the gate and publishes; no notice.
#   B1     the guest powered off and booted (BOOT_COMPLETED — a phone that
#          died): the same proof as U2.
#   B2     "Allow all the time" revoked, the guest restarted: the notice is
#          posted after the boot, no service runs.
#   U3     granted again, `install -r`: running and publishing again (K's
#          starting state).
#   K      the battery-optimisation exemption granted, the app process killed
#          with SIGKILL as a low-memory kill would: the system restarts the
#          sticky service, which passes the gate and publishes. Proven for that
#          condition only — without the exemption Android 12+ may refuse the
#          restart, and the copy says so.
#
# Every wait is a bounded poll. The host feeds the emulator's GPS with the
# Alice sentinel fix (host-needles.sh) while a leg waits for a publish.
#
# Usage (CI — the setup APK prebuilt before the emulator boots):
#   bash tooling/e2e/ci/run-android-resume.sh /tmp/integration-apks/android_resume_setup_test.apk
#
# Required env:
#   HAVEN_E2E_RELAY          ws:// URL of the strfry relay (default ws://10.0.2.2:7777).
#   RESUME_EMULATOR_OPTIONS  the options the workflow launched the emulator with
#                            (the restarts boot the same AVD with them).
# Optional env:
#   HAVEN_DRIVE_TIMEOUT      the setup drive's `timeout` (default 10m).
#   RESUME_PUBLISH_TIMEOUT   seconds for a resumed service's start, and again for
#                            its first publish (default 300: the 72 s repeat, a
#                            first fix and the service's start-up, with margin).
#   RESUME_NOTICE_TIMEOUT    seconds for the resume notice (default 90).
#   RESUME_BOOT_TIMEOUT      seconds for a restarted guest's boot (default 300).
#
# Writes /tmp/resume-logs/ (per-leg logcat and the drive log, uploaded), every
# file of it through the log-privacy gate first.

set -Eeuo pipefail

# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-log-lib.sh"
# shellcheck source=tooling/e2e/ci/app-install-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/app-install-lib.sh"
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logscan-gate.sh"

readonly PKG="com.oblivioustech.haven"
readonly DEVICE="emulator-5554"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HAVEN_DIR="$(cd "${SCRIPT_DIR}/../../../haven" && pwd)"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly TARGET_SETUP="integration_test/android_resume_setup_test.dart"
readonly LOG_DIR="/tmp/resume-logs"
# Outside LOG_DIR, which the workflow uploads whole.
readonly LOGSCAN_REPORT="/tmp/logscan-report-resume.ndjson"
readonly NEEDLE_DIR="/tmp/haven-soak/needles"

readonly DRIVE_TIMEOUT="${HAVEN_DRIVE_TIMEOUT:-10m}"
readonly DRIVE_KILL_AFTER_SECS=30
readonly RESUME_TIMEOUT="${RESUME_PUBLISH_TIMEOUT:-300}"
readonly NOTICE_TIMEOUT="${RESUME_NOTICE_TIMEOUT:-90}"
readonly BOOT_TIMEOUT="${RESUME_BOOT_TIMEOUT:-300}"
readonly SHUTDOWN_TIMEOUT="${RESUME_SHUTDOWN_TIMEOUT:-120}"
readonly ADB_READ_SECS="${RESUME_ADB_READ_SECS:-20}"
readonly GEO_SECS=5

# The service's own markers (background_location_task.dart,
# background_resume_gate.dart) and the setup drive's.
readonly MARK_ARMED='[ResumeSetup] sharing service armed'
readonly MARK_SYSTEM_START='[BackgroundTask] onStart (starter=TaskStarter.system)'
readonly MARK_PUBLISHED='[BackgroundTask] Published to'
readonly MARK_REFUSED='[BackgroundTask] system start refused'
# ResumeNotice.kt: its fixed id and channel, as `dumpsys notification` keys it.
readonly NOTICE_KEY="|${PKG}|4832|"
readonly NOTICE_CHANNEL="channel=haven_resume_v1"
readonly FGS_CLASS="com.pravera.flutter_foreground_task.service.ForegroundService"
readonly BG_PERM="android.permission.ACCESS_BACKGROUND_LOCATION"

# echo_log_tail <captured-log> [<lines>] — the ONLY way a captured log reaches
# the world-readable job log: the gate over that one file first, and the tail
# only when it passes.
echo_log_tail() {
  local log="$1" lines="${2:-60}" rc=0
  logscan_gate host "${NEEDLE_DIR}" -- --sink "logcat=${log}" --report "${LOGSCAN_REPORT}" || rc=$?
  if (( rc != 0 )); then
    echo "(tail of ${log##*/} withheld: log-privacy gate rc ${rc})" >&2
    return 0
  fi
  tail -n "${lines}" "${log}" >&2 || true
}

# --self-test — hermetic: no device, no relay. The wiring, read from this file
# with comments stripped: the gate library is sourced; the EXIT trap gates
# LOG_DIR; every echo of a captured log goes through echo_log_tail or
# drive_target, each gating before its one echo; the manifest is sealed before
# the trap; no `adb wait-for-device`; and the restart passes the workflow's own
# emulator options. Plus the helper itself: a refusing gate withholds a tail.
run_self_test() {
  local tmp fail=0 rc real_run body fn gate_line echo_line fake
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  fake="${tmp}/fake-scan.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_SCAN_RC}"' > "${fake}"
  printf 'line one\nline two\n' > "${tmp}/logcat.x.log"
  rc=0
  HAVEN_LOGSCAN= SECRET_SCAN="${fake}" FAKE_SCAN_RC=3 \
    echo_log_tail "${tmp}/logcat.x.log" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 0 )) || grep -qF 'line two' "${tmp}/out" || ! grep -qF 'withheld' "${tmp}/out"; then
    echo "SELF-TEST FAIL (echo_log_tail): a refusing gate must withhold the tail and say so (rc ${rc})" >&2
    fail=1
  fi
  rc=0
  HAVEN_LOGSCAN= SECRET_SCAN="${fake}" FAKE_SCAN_RC=0 \
    echo_log_tail "${tmp}/logcat.x.log" > "${tmp}/out" 2>&1 || rc=$?
  if (( rc != 0 )) || ! grep -qF 'line two' "${tmp}/out"; then
    echo "SELF-TEST FAIL (echo_log_tail): a clean gate must print the tail (rc ${rc})" >&2
    fail=1
  fi

  real_run="$(grep -v '^[[:space:]]*#' "${BASH_SOURCE[0]}" | sed '/^run_self_test() {/,/^}/d')"
  if ! grep -qE '^source .*/logscan-gate\.sh"$' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): logscan-gate.sh is no longer sourced" >&2
    fail=1
  fi
  body="$(sed -n '/^cleanup() {/,/^}/p' <<<"${real_run}")"
  if ! grep -qF 'logscan_gate_dir host "${NEEDLE_DIR}" "${LOG_DIR}" "${LOGSCAN_REPORT}"' <<<"${body}"; then
    echo "SELF-TEST FAIL (wiring): the EXIT trap no longer gates LOG_DIR through logscan_gate_dir" >&2
    fail=1
  fi
  for fn in echo_log_tail drive_target; do
    body="$(sed -n "/^${fn}() {/,/^}/p" <<<"${real_run}")"
    gate_line="$(grep -n 'logscan_gate host "${NEEDLE_DIR}" -- --sink' <<<"${body}" | cut -d: -f1 | head -n 1)"
    echo_line="$(grep -nE '^[[:space:]]*(cat|tail|head) ' <<<"${body}" | cut -d: -f1 | head -n 1)"
    if [[ -z "${gate_line}" || -z "${echo_line}" ]] || (( echo_line < gate_line )) \
       || (( "$(grep -cE '^[[:space:]]*(cat|tail|head) ' <<<"${body}")" != 1 )); then
      echo "SELF-TEST FAIL (wiring): ${fn} must gate (line ${gate_line:-none}) before its one echo (line ${echo_line:-none})" >&2
      fail=1
    fi
  done
  if sed '/^echo_log_tail() {/,/^}/d; /^drive_target() {/,/^}/d' <<<"${real_run}" \
       | grep -qE '(^|[;&|][[:space:]]*)[[:space:]]*(cat|tail|head|less|more)[[:space:]]+[^|]*(logcat|drivelog|drive\.|LOG_DIR)'; then
    echo "SELF-TEST FAIL (wiring): a captured log is echoed outside echo_log_tail/drive_target, i.e. before any gate" >&2
    fail=1
  fi
  if grep -qF 'wait-for-device' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): \`adb wait-for-device\` is in the real run; wait for the device with a bounded poll" >&2
    fail=1
  fi
  local seal_line trap_line
  seal_line="$(grep -n -m1 '^logscan_seal host "${NEEDLE_DIR}" "${SEAL_EXTRA\[@\]}" || seal_rc=$?$' "${BASH_SOURCE[0]}")"
  trap_line="$(grep -n -m1 '^trap cleanup EXIT$' "${BASH_SOURCE[0]}")"
  if [[ -z "${seal_line}" || -z "${trap_line}" ]] || (( ${seal_line%%:*} > ${trap_line%%:*} )); then
    echo "SELF-TEST FAIL (wiring): the manifest must be sealed once, before the EXIT trap is armed" >&2
    fail=1
  fi
  body="$(sed -n '/^restart_guest() {/,/^}/p' <<<"${real_run}")"
  if ! grep -qF '${RESUME_EMULATOR_OPTIONS}' <<<"${body}" || ! grep -qF -- '-no-snapshot-load' <<<"${body}"; then
    echo "SELF-TEST FAIL (wiring): the restart must boot the AVD with the workflow's own options and no snapshot" >&2
    fail=1
  fi
  local workflow="${SCRIPT_DIR}/../../../.github/workflows/e2e-android-resume.yml" launched passed
  launched="$(grep -m1 -E '^[[:space:]]+emulator-options: -no-snapshot-save' "${workflow}" | sed -E 's/^[[:space:]]+emulator-options: //')"
  passed="$(grep -m1 -E '^[[:space:]]+RESUME_EMULATOR_OPTIONS: ' "${workflow}" | sed -E 's/^[[:space:]]+RESUME_EMULATOR_OPTIONS: //')"
  if [[ -z "${launched}" || "${launched}" != "${passed}" ]]; then
    echo "SELF-TEST FAIL (wiring): RESUME_EMULATOR_OPTIONS ('${passed}') differs from the emulator step's options ('${launched}')" >&2
    fail=1
  fi
  if (( fail )); then
    echo "run-android-resume.sh: self-test FAILED" >&2
    return 1
  fi
  echo "run-android-resume.sh: self-test passed (echo_log_tail withholds a tail the gate refuses; the gate library is sourced, the EXIT trap gates LOG_DIR, every echo of a captured log goes through the gate first, the manifest is sealed before the trap, no adb wait-for-device, and the restart boots the AVD with the workflow's own options)."
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly COORD_LAT="${HN_COORD_ALICE%%,*}"
readonly COORD_LON="${HN_COORD_ALICE##*,}"
LOGCAT_PID=""
GEO_PID=""

cleanup() {
  local rc=$?
  trap - EXIT
  stop_geo
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  echo "== Log-privacy gate over ${LOG_DIR} (Security Rules 6 and 15) =="
  if ! logscan_gate_dir host "${NEEDLE_DIR}" "${LOG_DIR}" "${LOGSCAN_REPORT}"; then
    echo "ERROR: log-privacy gate failed on the resume lane's logs — see the line(s) above." >&2
    rc=1
  fi
  exit "${rc}"
}

# The drive floor is what `flutter drive` prints on the HOST in a complete
# --keep-app-running transcript (run-m7-background-catchup.sh derives the 9).
# No relay log is captured here.
readonly -a SEAL_EXTRA=(--floor drive=9)
seal_rc=0
logscan_seal host "${NEEDLE_DIR}" "${SEAL_EXTRA[@]}" || seal_rc=$?
if (( seal_rc != 0 )); then
  echo "ERROR: could not seal this lane's needle manifest (rc ${seal_rc})." >&2
  exit 1
fi

trap cleanup EXIT

fail() {
  echo "RESUME-LANE-FAIL: $*" >&2
  exit 1
}

# start_logcat <file> [keep] — clears the device buffers first so a leg sees only
# its own markers, except after a boot (`keep`): the receiver may already have
# started the service, and a fresh boot's buffer holds nothing older.
start_logcat() {
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  if [[ "${2:-}" != keep ]]; then
    adb -s "${DEVICE}" logcat -c || true
    adb -s "${DEVICE}" logcat -b crash -c || true
  fi
  adb -s "${DEVICE}" logcat -v threadtime > "$1" 2>&1 &
  LOGCAT_PID=$!
}

# The emulator's GPS, fed while a leg waits for a publish. `geo fix` takes
# LONGITUDE first.
start_geo() {
  stop_geo
  ( while :; do
      adb -s "${DEVICE}" emu geo fix "${COORD_LON}" "${COORD_LAT}" >/dev/null 2>&1 || true
      sleep "${GEO_SECS}"
    done ) &
  GEO_PID=$!
}

stop_geo() {
  if [[ -n "${GEO_PID}" ]] && kill -0 "${GEO_PID}" 2>/dev/null; then
    kill "${GEO_PID}" 2>/dev/null || true
  fi
  GEO_PID=""
}

wait_for_marker() {
  local logfile="$1" marker="$2" timeout_s="$3"
  local deadline=$(( SECONDS + timeout_s ))
  while (( SECONDS < deadline )); do
    grep -aqF -- "${marker}" "${logfile}" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

notice_posted() {
  local out
  out="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell dumpsys notification --noredact 2>/dev/null || true)"
  grep -F -- "${NOTICE_KEY}" <<<"${out}" | grep -qF -- "${NOTICE_CHANNEL}"
}

wait_for_notice() {
  local deadline=$(( SECONDS + NOTICE_TIMEOUT ))
  while (( SECONDS < deadline )); do
    notice_posted && return 0
    sleep 2
  done
  return 1
}

service_foreground() {
  local out
  out="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell dumpsys activity services "${PKG}" 2>/dev/null || true)"
  grep -qF -- "${FGS_CLASS}" <<<"${out}" && grep -qF 'isForeground=true' <<<"${out}"
}

background_granted() {
  local out
  out="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell dumpsys package "${PKG}" 2>/dev/null || true)"
  grep -qF "${BG_PERM}: granted=true" <<<"${out}"
}

assert_no_crash() {
  local out
  out="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" logcat -b crash -d 2>/dev/null || true)"
  if grep -qF "${PKG}" <<<"${out}"; then
    fail "$1: the crash buffer names ${PKG}."
  fi
}

grant_perms() {
  local perm
  for perm in android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION \
    android.permission.POST_NOTIFICATIONS; do
    adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" >/dev/null 2>&1 \
      || fail "could not grant ${perm}"
  done
}

drive_target() {
  local apk="$1" target="$2" drivelog="$3" drc=0
  echo "[drive] ${target} on ${DEVICE} (timeout ${DRIVE_TIMEOUT})"
  # --keep-app-running: the service the drive starts is the state every leg
  # tests, and flutter drive's default teardown would force-stop it.
  ( cd "${HAVEN_DIR}" && timeout --kill-after="${DRIVE_KILL_AFTER_SECS}s" "${DRIVE_TIMEOUT}" flutter drive \
      --no-pub \
      --keep-app-running \
      --device-id "${DEVICE}" \
      --use-application-binary "${apk}" \
      --driver "${DRIVER_FILE}" \
      --target "${target}" ) > "${drivelog}" 2>&1 || drc=$?
  local grc=0
  logscan_gate host "${NEEDLE_DIR}" -- --sink "drive=${drivelog}" --report "${LOGSCAN_REPORT}" || grc=$?
  if (( grc != 0 )); then
    fail "log-privacy gate failed on the drive log of ${target} (rc ${grc})."
  fi
  cat "${drivelog}" || true
  (( drc == 0 )) || fail "drive of ${target} failed (rc=${drc})."
  if drive_log_reports_test_failure "${drivelog}"; then
    drive_log_failure_evidence "${drivelog}" >&2
    fail "drive of ${target} exited 0 but the on-device suite reported failures."
  fi
}

# A resumed service: a SYSTEM start, then a publish, then no notice.
expect_resumed() {
  local leg="$1" log="$2"
  start_geo
  if ! wait_for_marker "${log}" "${MARK_SYSTEM_START}" "${RESUME_TIMEOUT}"; then
    echo_log_tail "${log}"
    fail "${leg}: no system start of the service within ${RESUME_TIMEOUT}s."
  fi
  if ! wait_for_marker "${log}" "${MARK_PUBLISHED}" "${RESUME_TIMEOUT}"; then
    echo_log_tail "${log}"
    fail "${leg}: the resumed service did not publish within ${RESUME_TIMEOUT}s."
  fi
  stop_geo
  service_foreground || fail "${leg}: the service published but is not a foreground service."
  if grep -aqF -- "${MARK_REFUSED}" "${log}"; then
    fail "${leg}: the gate refused a start the resume rule allows."
  fi
  notice_posted && fail "${leg}: the resume notice is posted although sharing resumed."
  assert_no_crash "${leg}"
  echo "[${leg}] PASS: system start, published, no notice."
}

# A refused resume: the notice, and no service.
expect_notice() {
  local leg="$1" log="$2"
  if ! wait_for_notice; then
    echo_log_tail "${log}"
    fail "${leg}: no resume notice within ${NOTICE_TIMEOUT}s."
  fi
  # The notice is the positive marker that the decision ran, so the service's
  # absence is read once, with no timed absence wait.
  service_foreground && fail "${leg}: a service runs although the resume rule refuses it."
  assert_no_crash "${leg}"
  echo "[${leg}] PASS: the resume notice is posted, no service runs."
}

restart_guest() {
  local emulator="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}/emulator/emulator" avd
  local port="${DEVICE#emulator-}"
  [[ -x "${emulator}" ]] || fail "no emulator launcher under the SDK root to boot the guest again."
  [[ -n "${RESUME_EMULATOR_OPTIONS:-}" ]] || fail "RESUME_EMULATOR_OPTIONS is unset."
  avd="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" emu avd name 2>/dev/null | head -n 1 | tr -d '\r' || true)"
  [[ -n "${avd}" && "${avd}" != KO* ]] || fail "the emulator did not name its AVD."
  timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell reboot -p >/dev/null 2>&1 || true
  local deadline=$(( SECONDS + SHUTDOWN_TIMEOUT ))
  while (( SECONDS < deadline )); do
    pgrep -f -- "-avd ${avd}" >/dev/null 2>&1 || break
    sleep 2
  done
  pgrep -f -- "-avd ${avd}" >/dev/null 2>&1 \
    && fail "the emulator was still running ${SHUTDOWN_TIMEOUT}s after the guest was powered off."
  # shellcheck disable=SC2086 # the workflow's emulator options, split as the action splits them
  setsid "${emulator}" -port "${port}" -avd "${avd}" ${RESUME_EMULATOR_OPTIONS} -no-snapshot-load \
    > /dev/null 2>&1 < /dev/null &
}

# Complete only once a read has seen the property NOT at 1, so the guest being
# left can never count.
wait_for_boot() {
  local deadline=$(( SECONDS + BOOT_TIMEOUT )) bc seen_down=0
  while (( SECONDS < deadline )); do
    bc="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "${bc}" != "1" ]]; then
      seen_down=1
    elif (( seen_down )); then
      return 0
    fi
    sleep 2
  done
  return 1
}

reboot_leg() {
  local leg="$1"
  echo "[${leg}] restarting the guest: powered off, then the same AVD booted again..."
  restart_guest
  wait_for_boot || fail "${leg}: the guest did not boot within ${BOOT_TIMEOUT}s of its restart."
  adb -s "${DEVICE}" shell wm dismiss-keyguard >/dev/null 2>&1 || true
}

main() {
  local apk="${1:-}"
  [[ -f "${apk}" ]] || fail "usage: run-android-resume.sh <android_resume_setup_test.apk>"
  [[ -f "${HAVEN_DIR}/${DRIVER_FILE}" ]] || fail "${DRIVER_FILE} missing."
  mkdir -p "${LOG_DIR}"
  echo "Android resume lane — relay=${RELAY_URL}"

  echo "=== setup: fresh install, drive, service running ==="
  install_fresh "${DEVICE}" "${apk}" || fail "setup: the fresh install did not complete."
  grant_perms
  start_logcat "${LOG_DIR}/logcat.setup.log"
  drive_target "${apk}" "${TARGET_SETUP}" "${LOG_DIR}/drive.setup.log"
  grep -aqF -- "${MARK_ARMED}" "${LOG_DIR}/drive.setup.log" || fail "setup: the drive never armed the service."
  service_foreground || fail "setup: the service is not running after the drive."
  background_granted && fail "setup: \"Allow all the time\" is already granted; U1 would prove nothing."

  echo "=== U1: update without \"Allow all the time\" ==="
  start_logcat "${LOG_DIR}/logcat.u1.log"
  install_app "${DEVICE}" "${apk}" || fail "U1: install -r did not complete."
  expect_notice U1 "${LOG_DIR}/logcat.u1.log"

  echo "=== U2: update with \"Allow all the time\" ==="
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${BG_PERM}" >/dev/null 2>&1 || fail "U2: could not grant ${BG_PERM}."
  background_granted || fail "U2: ${BG_PERM} does not read back as granted."
  start_logcat "${LOG_DIR}/logcat.u2.log"
  install_app "${DEVICE}" "${apk}" || fail "U2: install -r did not complete."
  expect_resumed U2 "${LOG_DIR}/logcat.u2.log"

  echo "=== B1: reboot with \"Allow all the time\" ==="
  reboot_leg B1
  start_logcat "${LOG_DIR}/logcat.b1.log" keep
  expect_resumed B1 "${LOG_DIR}/logcat.b1.log"

  echo "=== B2: reboot after \"Allow all the time\" is revoked ==="
  start_logcat "${LOG_DIR}/logcat.b2-revoke.log"
  adb -s "${DEVICE}" shell pm revoke "${PKG}" "${BG_PERM}" >/dev/null 2>&1 || fail "B2: could not revoke ${BG_PERM}."
  background_granted && fail "B2: ${BG_PERM} still reads back as granted."
  reboot_leg B2
  if grep -aqF -- "${MARK_REFUSED}" "${LOG_DIR}/logcat.b2-revoke.log"; then
    echo "[B2] note: a sticky restart reached the gate before the reboot and was refused (notice + stop)." >&2
  fi
  start_logcat "${LOG_DIR}/logcat.b2.log" keep
  expect_notice B2 "${LOG_DIR}/logcat.b2.log"

  echo "=== U3: update with \"Allow all the time\" again ==="
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${BG_PERM}" >/dev/null 2>&1 || fail "U3: could not grant ${BG_PERM}."
  start_logcat "${LOG_DIR}/logcat.u3.log"
  install_app "${DEVICE}" "${apk}" || fail "U3: install -r did not complete."
  expect_resumed U3 "${LOG_DIR}/logcat.u3.log"

  echo "=== K: the process killed, battery optimisation off ==="
  adb -s "${DEVICE}" shell cmd deviceidle whitelist "+${PKG}" >/dev/null 2>&1 \
    || fail "K: could not exempt ${PKG} from battery optimisation."
  local pid
  pid="$(timeout "${ADB_READ_SECS}" adb -s "${DEVICE}" shell pidof "${PKG}" 2>/dev/null | tr -d '\r' || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] || fail "K: no single process for ${PKG} (got '${pid}')."
  start_logcat "${LOG_DIR}/logcat.k.log"
  # The debug app's own uid may signal it: a SIGKILL, as a low-memory kill
  # delivers, with no chance to stop the service cleanly.
  adb -s "${DEVICE}" shell run-as "${PKG}" kill -9 "${pid}" >/dev/null 2>&1 || fail "K: could not kill ${PKG}."
  expect_resumed K "${LOG_DIR}/logcat.k.log"

  echo "Android resume lane: ALL LEGS PASSED (U1 U2 B1 B2 U3 K)"
}

main "$@"
