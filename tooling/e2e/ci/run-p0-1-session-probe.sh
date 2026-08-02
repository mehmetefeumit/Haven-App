#!/usr/bin/env bash
#
# P0-1 GATING EXPERIMENT — does the Rule-14 MLS guard survive the death of the
# main Flutter isolate?
#
# TEMPORARY. Delete this script, `haven/integration_test/p0_1_session_probe_test.dart`,
# and the probe in `background_location_task.dart` once the answer is recorded
# in `docs/P0_1_FGS_SESSION_PLAN.md` §2.
#
# ## Why this exists
#
# The P0-1 fix plan proposes the foreground service stop opening its own MLS
# session and route work to the main isolate instead, falling back to opening
# one itself when no main isolate exists. Two independent reviews argued that
# fallback can never succeed, because the guard is held by an `Arc` inside a
# Rust process-global that OUTLIVES the isolate: when the Activity is destroyed
# there is nobody to route to AND no way to acquire.
#
# If they are right, the routing design is unbuildable as specified. That is a
# ~10-line question standing in front of a multi-week refactor, so it gets
# answered by observation before anything is built.
#
# ## Method
#
#   1. Drive a target that leaves the main isolate holding the MLS guard and a
#      foreground service running.
#   2. Turn ON "Don't keep activities" (`always_finish_activities`), then press
#      HOME. Android destroys the Activity immediately — and with it the main
#      `FlutterEngine`, since `MainActivity` caches none — while the
#      `location`-typed foreground service keeps the PROCESS alive. That is the
#      swipe-from-recents state, reachable deterministically from adb.
#   3. Wait for the next FGS tick and read the probe's verdict.
#
# Reading the result:
#
#   REFUSED rule14=true  -> the guard survived the isolate. The plan's
#                           cold-start fallback is dead on arrival; the
#                           architecture must change (Rust-side liveness epoch,
#                           or invert so the FGS owns the session).
#   ACQUIRED             -> the guard died with the isolate. The routing design
#                           is viable as specified.
#
# Either answer is a successful run. This script exits 0 when it obtains a
# verdict and non-zero only when it fails to obtain one.
#
# Usage:
#   run-p0-1-session-probe.sh <apk> [target.dart]
#   run-p0-1-session-probe.sh --self-test
#
set -Eeuo pipefail

# shellcheck source=tooling/e2e/ci/drive-log-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/drive-log-lib.sh"

readonly MARK_ARMED='[P0-1-PROBE] ARMED'
readonly MARK_ACQUIRED='[P0-1-PROBE] ACQUIRED'
readonly MARK_REFUSED='[P0-1-PROBE] REFUSED'
readonly MARK_SKIPPED='[P0-1-PROBE] SKIPPED'

# classify_verdict <logfile> — echoes ACQUIRED | REFUSED | SKIPPED | NONE for
# the LAST probe line, which is the one that ran after the Activity died.
# Earlier lines are the control (Activity alive → expected REFUSED), so taking
# the last is what distinguishes the two phases.
classify_verdict() {
  local log="${1:-}"
  [[ -f "${log}" ]] || { echo NONE; return 0; }
  local last
  last="$(grep -aoE '\[P0-1-PROBE\] (ACQUIRED|REFUSED|SKIPPED)' "${log}" 2>/dev/null | tail -1 || true)"
  case "${last}" in
    *ACQUIRED*) echo ACQUIRED ;;
    *REFUSED*) echo REFUSED ;;
    *SKIPPED*) echo SKIPPED ;;
    *) echo NONE ;;
  esac
}

run_self_test() {
  local tmp fail=0 got
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # (1) The control line then the post-destruction line: the LAST one wins.
  #     Taking the first would report the control and answer the wrong question.
  printf '%s\n' \
    '01-01 00:00:01.000  111  111 I flutter : [P0-1-PROBE] ARMED — ...' \
    '01-01 00:01:13.000  111  120 I flutter : [P0-1-PROBE] REFUSED rule14=true type=String — ...' \
    '01-01 00:02:25.000  111  120 I flutter : [P0-1-PROBE] ACQUIRED — the MLS guard was FREE ...' \
    > "${tmp}/acquired.log"
  got="$(classify_verdict "${tmp}/acquired.log")"
  [[ "${got}" == "ACQUIRED" ]] || { echo "SELF-TEST FAIL (1): got '${got}'" >&2; fail=1; }

  # (2) The predicted outcome: still refused after the Activity died.
  printf '%s\n' \
    '01-01 00:01:13.000  111  120 I flutter : [P0-1-PROBE] REFUSED rule14=true type=String — ...' \
    '01-01 00:02:25.000  111  120 I flutter : [P0-1-PROBE] REFUSED rule14=true type=String — ...' \
    > "${tmp}/refused.log"
  got="$(classify_verdict "${tmp}/refused.log")"
  [[ "${got}" == "REFUSED" ]] || { echo "SELF-TEST FAIL (2): got '${got}'" >&2; fail=1; }

  # (3) No probe line at all — the define was omitted, so the probe compiled
  #     out. Must NOT be mistaken for a verdict.
  printf '%s\n' '01-01 00:00:01.000  111  111 I flutter : [BackgroundTask] onStart (starter=x)' \
    > "${tmp}/none.log"
  got="$(classify_verdict "${tmp}/none.log")"
  [[ "${got}" == "NONE" ]] || { echo "SELF-TEST FAIL (3): got '${got}'" >&2; fail=1; }

  # (4) SKIPPED (no identity) is its own outcome, never silently a verdict.
  printf '%s\n' '01-01 00:01:13.000  111  120 I flutter : [P0-1-PROBE] SKIPPED — no identity loaded ...' \
    > "${tmp}/skipped.log"
  got="$(classify_verdict "${tmp}/skipped.log")"
  [[ "${got}" == "SKIPPED" ]] || { echo "SELF-TEST FAIL (4): got '${got}'" >&2; fail=1; }

  if (( fail != 0 )); then
    echo "run-p0-1-session-probe.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-p0-1-session-probe.sh --self-test: all 4 fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

readonly PKG="com.oblivioustech.haven"
readonly DEVICE="emulator-5554"
readonly DRIVER_FILE="test_driver/integration_test.dart"
readonly LOG_DIR="/tmp/p0-1-probe-logs"
readonly APK="${1:-/tmp/integration-apks/p0_1_session_probe_test.apk}"
readonly TARGET="${2:-integration_test/p0_1_session_probe_test.dart}"
readonly DRIVE_TIMEOUT="${PROBE_DRIVE_TIMEOUT:-10m}"
# Two FGS ticks (kBackgroundRepeatInterval = 72s) plus slack, so the verdict
# cannot be missed by landing between ticks.
readonly OBSERVE_SECS="${PROBE_OBSERVE_SECS:-200}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "${script_dir}/../../.." && pwd)"
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"
readonly START_STRFRY="${script_dir}/start-strfry.sh"
readonly STOP_STRFRY="${script_dir}/stop-strfry.sh"

mkdir -p "${LOG_DIR}"
readonly LOGCAT_FILE="${LOG_DIR}/logcat.probe.log"
readonly DRIVE_LOG="${LOG_DIR}/flutter-drive.log"
LOGCAT_PID=""
ALWAYS_FINISH_RESTORED=0

cleanup() {
  local rc=$?
  trap - EXIT
  # ALWAYS restore the developer setting — leaving "Don't keep activities" on
  # would silently break every later lane on a cached AVD.
  if (( ALWAYS_FINISH_RESTORED == 0 )); then
    adb -s "${DEVICE}" shell settings put global always_finish_activities 0 \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "${LOGCAT_PID}" ]] && kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  if ! bash "${SECRET_SCAN}" "${LOG_DIR}"; then
    find "${LOG_DIR}" -type f -name '*.log' -delete 2>/dev/null || true
    echo "logs withheld: secret-leak guard tripped" > "${LOG_DIR}/LEAK_DETECTED.txt"
    echo "ERROR: secret-leak guard tripped — logs deleted, not uploaded." >&2
    rc=1
  fi
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

fail() {
  echo "P0-1-PROBE-FAIL: $*" >&2
  echo "---- [P0-1-PROBE] / [BackgroundTask] lines ----" >&2
  grep -aE '\[P0-1-PROBE\]|\[BackgroundTask\]' "${LOGCAT_FILE}" 2>/dev/null | tail -30 >&2 \
    || echo "(none)" >&2
  exit 1
}

echo "Phase 0/4 — hermetic relay + device..."
bash "${START_STRFRY}"
adb -s "${DEVICE}" wait-for-device
[[ -f "${APK}" ]] || fail "APK not found: ${APK}"

echo "Phase 1/4 — installing and granting..."
adb -s "${DEVICE}" shell am force-stop "${PKG}" || true
adb -s "${DEVICE}" uninstall "${PKG}" >/dev/null 2>&1 || true
adb -s "${DEVICE}" install -r "${APK}"
for perm in android.permission.ACCESS_FINE_LOCATION \
            android.permission.ACCESS_COARSE_LOCATION \
            android.permission.POST_NOTIFICATIONS; do
  adb -s "${DEVICE}" shell pm grant "${PKG}" "${perm}" || \
    fail "could not grant ${perm}"
done

echo "Phase 2/4 — arming (drive)..."
adb -s "${DEVICE}" logcat -c || true
adb -s "${DEVICE}" logcat -v threadtime > "${LOGCAT_FILE}" 2>&1 &
LOGCAT_PID=$!

drc=0
# --keep-app-running: the process must survive the drive, or there is nothing
# left holding the guard and nothing left to observe.
( cd "${HAVEN_DIR}" && timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub --keep-app-running \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${TARGET}" ) > "${DRIVE_LOG}" 2>&1 || drc=$?
if bash "${SECRET_SCAN}" "${DRIVE_LOG}" >/dev/null 2>&1; then
  cat "${DRIVE_LOG}" || true
else
  echo "drive log withheld — secret-leak guard tripped." >&2
fi
if (( drc != 0 )) || drive_log_reports_test_failure "${DRIVE_LOG}"; then
  fail "the arming drive did not complete (rc=${drc}); nothing to measure."
fi
grep -aqF -- "${MARK_ARMED}" "${LOGCAT_FILE}" 2>/dev/null || \
  fail "no '${MARK_ARMED}' marker — the target did not arm, or the probe was \
compiled out (was the APK built with --dart-define=HAVEN_P0_1_PROBE=true?)."
echo "Phase 2/4 — armed."

echo "Phase 3/4 — destroying the Activity while the service survives..."
# "Don't keep activities": the Activity is finished the moment it stops, so
# HOME destroys it — and the main FlutterEngine with it.
adb -s "${DEVICE}" shell settings put global always_finish_activities 1

# READ IT BACK. `settings put` is silent on failure, and a probe that never
# destroyed the Activity still reports "REFUSED" — the PREDICTED answer — which
# is the most dangerous possible false positive. Run 30770222629 did exactly
# that: the verdict looked like a confirmation while logcat showed no Haven
# activity transition at all.
setting="$(adb -s "${DEVICE}" shell settings get global always_finish_activities | tr -d '\r')"
if [[ "${setting}" != "1" ]]; then
  fail "could not enable always_finish_activities (read back '${setting}'). \
Without it the Activity is only stopped, never destroyed, and the probe cannot \
reach the state it exists to measure."
fi

adb -s "${DEVICE}" shell input keyevent HOME

# HARD PRECONDITION: the Activity must actually be GONE. Bounded poll — the
# finish is asynchronous.
activity_gone=0
deadline=$(( SECONDS + 30 ))
while (( SECONDS < deadline )); do
  if ! adb -s "${DEVICE}" shell dumpsys activity activities 2>/dev/null \
       | grep -q "${PKG}/.MainActivity"; then
    activity_gone=1
    break
  fi
  sleep 2
done
if (( activity_gone == 0 )); then
  echo "---- surviving activity records ----" >&2
  adb -s "${DEVICE}" shell dumpsys activity activities 2>/dev/null \
    | grep -a "${PKG}" | head -10 >&2 || true
  fail "the Activity was NOT destroyed within 30s, so the main isolate is \
almost certainly still alive. Any verdict from this run would be meaningless: \
'the guard is held' is trivially true while the holder is still running. This \
is INCONCLUSIVE, not evidence for either branch."
fi
sleep 3

# The whole experiment is void if the service died with the Activity.
if ! adb -s "${DEVICE}" shell dumpsys activity services "${PKG}" 2>/dev/null \
     | grep -q "ForegroundService"; then
  fail "the foreground service did NOT survive Activity destruction, so the \
process may be gone entirely — this run cannot answer the question. (It is also \
a finding in its own right: it would mean the FGS cannot outlive the UI here.)"
fi
echo "Phase 3/4 — Activity destroyed AND foreground service still listed: the \
probe is in the state it exists to measure."

echo "Phase 4/4 — observing up to ${OBSERVE_SECS}s for the post-destruction verdict..."
deadline=$(( SECONDS + OBSERVE_SECS ))
while (( SECONDS < deadline )); do
  if grep -aqE -- '\[P0-1-PROBE\] (ACQUIRED|REFUSED|SKIPPED)' "${LOGCAT_FILE}" 2>/dev/null; then
    # Keep sampling to the deadline: the FIRST post-HOME line may still be the
    # control if a tick was already in flight when the Activity died.
    :
  fi
  sleep 5
done

adb -s "${DEVICE}" shell settings put global always_finish_activities 0 || true
ALWAYS_FINISH_RESTORED=1

verdict="$(classify_verdict "${LOGCAT_FILE}")"
echo "---- all probe lines ----"
grep -aF '[P0-1-PROBE]' "${LOGCAT_FILE}" || true
echo "------------------------"

case "${verdict}" in
  REFUSED)
    echo "P0-1 PROBE VERDICT: REFUSED — the Rule-14 guard SURVIVED the main"
    echo "isolate's death. The fix plan's cold-start fallback can never succeed,"
    echo "so the routing design (b′) is unbuildable as specified. Take (b″) — a"
    echo "Rust-side liveness epoch that lets the FGS reclaim the slot — or (c),"
    echo "inverting so the FGS owns the session. Record this in"
    echo "docs/P0_1_FGS_SESSION_PLAN.md §2."
    ;;
  ACQUIRED)
    echo "P0-1 PROBE VERDICT: ACQUIRED — the guard was released with the main"
    echo "isolate. The routing design's cold-start fallback is viable as"
    echo "specified. Record this in docs/P0_1_FGS_SESSION_PLAN.md §2, and note"
    echo "that both confirmation reviews predicted the opposite — re-check WHY"
    echo "before relying on it."
    ;;
  SKIPPED)
    fail "the probe ran but had no identity loaded, so it never attempted an \
open. The experiment is inconclusive."
    ;;
  *)
    fail "no probe verdict within ${OBSERVE_SECS}s of destroying the Activity. \
Either the foreground service stopped ticking (check for onDestroy above) or the \
probe was compiled out."
    ;;
esac
