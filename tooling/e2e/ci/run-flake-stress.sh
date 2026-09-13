#!/usr/bin/env bash
#
# Active flake-stress driver (backlog CI-5). Runs ONE Haven E2E target
# (default: the consolidated `e2e_combined.dart` flow) N times on the
# action-booted emulator-5554 and FAILS if ANY single iteration fails.
#
# This is the ACTIVE counterpart to the report-only e2e-flakiness.yml
# monitor: that one tallies historical pass/fail from the Actions API
# and never fails the build; THIS one provokes flakiness on demand and
# turns the build red the moment an iteration fails, so an intermittent
# regression is caught proactively instead of discovered weeks later in
# the aggregate.
#
# # Per-iteration relay reset (no state leak between iterations)
#
# Every iteration gets a freshly wiped strfry (stop-strfry.sh +
# start-strfry.sh). The scenario seeds its actors from byte-identical
# deterministic seeds every run, so events from iteration K would be
# served back to iteration K+1 as stale state and could mask a real
# flake (or manufacture a false one). Wiping between iterations makes
# each iteration a genuinely independent trial — which is the entire
# point of a flake test.
#
# # The APK is built ONCE, before the emulator boots
#
# The target is the same for every iteration, so its APK is built a
# single time by the workflow BEFORE the emulator boots (the multi-GB
# Rust-NDK + Gradle peak must not coincide with a resident emulator —
# the historical lost-runner cause; see docs/E2E_TROUBLESHOOTING.md).
# That staged /tmp/scenario.apk is reused for every iteration:
# run-single-avd-scenario.sh detects it and does only install + grant +
# drive. No Gradle runs while the emulator is up.
#
# # Why a checked-in script
#
# The reactivecircus/android-emulator-runner action runs each line of a
# multi-line `script:` in a separate `sh -c`, so loop state would be
# lost. Wrapping the whole loop in one `bash <path>` keeps it coherent
# — same rationale as the other tooling/e2e/ci scripts.
#
# Usage:
#   bash tooling/e2e/ci/run-flake-stress.sh <iterations> [<target.dart>]
#
# Args:
#   <iterations>   Positive integer (1..=1000). Number of independent
#                  runs of the target.
#   <target.dart>  Optional. Defaults to
#                  integration_test/e2e/e2e_combined.dart.
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay (forwarded to
#                    run-single-avd-scenario.sh).
#
# Optional env (forwarded to start-strfry.sh / stop-strfry.sh):
#   STRFRY_IMAGE, STRFRY_DATA_DIR, STRFRY_CONTAINER, STRFRY_PORT,
#   STRFRY_READY_TIMEOUT  — see start-strfry.sh.
#
# Side effects:
#   - Per iteration, run-single-avd-scenario.sh overwrites
#     /tmp/adb-logcat.log and /tmp/flutter-drive.log; on a FAILED
#     iteration we copy both to /tmp/flake-logs/iter-<n>.{logcat,drive}.log
#     so the failing iteration's evidence survives later iterations.
#   - Resets the strfry container + its data dir between iterations.

set -euo pipefail

# scan_dir_or_contain <dir> — the secret-leak gate (Security Rules 6 and 15)
# over the evidence directory the workflow uploads `if: always()`. A leak
# (rc 1) REMOVES every *.log the scan walked and leaves a LEAK.marker naming
# only the pattern label(s), so the upload publishes the verdict and not the
# line; rc 3 (nothing scannable) keeps the directory as it is. Reads
# SECRET_SCAN at call time so --self-test can hand it a fake scanner.
scan_dir_or_contain() {
  local dir="$1" rc=0 err
  err="$(mktemp)"
  bash "${SECRET_SCAN}" "${dir}" 2>"${err}" || rc=$?
  cat "${err}" >&2
  if (( rc == 1 )); then
    find "${dir}" -type f -name '*.log' -exec rm -f -- {} +
    {
      echo "secret-leak scan: LEAK — every *.log under this directory was removed before upload (scan-logs-for-secrets.sh rc 1)"
      sed -n 's/^LEAK: .* \[\(.*\)\] at line(s):.*$/pattern: \1/p' "${err}" | sort -u
    } > "${dir}/LEAK.marker"
    echo "ERROR: secret-leak guard tripped on ${dir}; removed its *.log files and" \
         "left ${dir}/LEAK.marker (pattern labels only)." >&2
  fi
  rm -f "${err}"
  return "${rc}"
}

# --self-test — hermetic: no device, no docker, no relay. Proves the gate
# CONTAINS, driven with a FAKE scanner: rc 1 removes every *.log under the
# directory (and nothing else) and leaves a LEAK.marker naming the pattern
# label only; rc 3 and rc 0 leave the directory untouched; the verdict comes
# back unchanged.
run_self_test() {
  local tmp fail=0 dir fake want rc SECRET_SCAN
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  fake="${tmp}/fake-scan.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [[ "${FAKE_SCAN_RC}" == 1 ]]; then echo "LEAK: $1/iter-3.logcat.log [bech32 nsec (private key)] at line(s): 7" >&2; fi' \
    'exit "${FAKE_SCAN_RC}"' > "${fake}"
  SECRET_SCAN="${fake}"
  dir="${tmp}/logs"
  for want in 1 3 0; do
    rm -rf "${dir}"
    mkdir -p "${dir}/nested"
    printf 'a\n' > "${dir}/iter-3.logcat.log"
    printf 'b\n' > "${dir}/nested/drive.log"
    printf 'c\n' > "${dir}/notes.txt"
    export FAKE_SCAN_RC="${want}"
    rc=0
    scan_dir_or_contain "${dir}" 2>/dev/null || rc=$?
    if (( rc != want )); then
      echo "SELF-TEST FAIL: the gate returned ${rc} for a scanner rc of ${want}" >&2
      fail=1
    fi
    if (( want == 1 )); then
      if [[ -e "${dir}/iter-3.logcat.log" || -e "${dir}/nested/drive.log" ]]; then
        echo "SELF-TEST FAIL: a leak (rc 1) left a scanned *.log on disk for the" \
             "if: always() upload to publish" >&2
        fail=1
      fi
      if [[ ! -e "${dir}/notes.txt" ]]; then
        echo "SELF-TEST FAIL: rc 1 removed a file the scan never walked" >&2
        fail=1
      fi
      if [[ ! -f "${dir}/LEAK.marker" ]]; then
        echo "SELF-TEST FAIL: rc 1 left no LEAK.marker, so the upload carries no verdict" >&2
        fail=1
      elif ! grep -qF 'pattern: bech32 nsec (private key)' "${dir}/LEAK.marker"; then
        echo "SELF-TEST FAIL: LEAK.marker does not name the pattern label" >&2
        fail=1
      elif grep -qE 'iter-3|at line' "${dir}/LEAK.marker"; then
        echo "SELF-TEST FAIL: LEAK.marker carries more than the label (a file or line)" >&2
        fail=1
      fi
    elif [[ ! -e "${dir}/iter-3.logcat.log" || ! -e "${dir}/nested/drive.log" \
            || -e "${dir}/LEAK.marker" ]]; then
      echo "SELF-TEST FAIL: scanner rc ${want} touched a directory it had no leak to contain" >&2
      fail=1
    fi
  done
  unset FAKE_SCAN_RC
  if (( fail )); then
    echo "run-flake-stress.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-flake-stress.sh: self-test passed (the secret-leak gate removes exactly the *.log files it scanned on a leak, leaves a labels-only LEAK.marker, and touches nothing on rc 3 or rc 0)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <iterations> [<target.dart>]" >&2
  exit 2
fi

readonly ITERATIONS="$1"
readonly TARGET="${2:-integration_test/e2e/e2e_combined.dart}"

# Validate iterations: a positive integer, capped to keep a runaway
# `workflow_dispatch` input from booking the runner indefinitely.
if ! [[ "${ITERATIONS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: iterations must be a positive integer, got '${ITERATIONS}'" >&2
  exit 2
fi
if (( ITERATIONS > 1000 )); then
  echo "ERROR: iterations capped at 1000 (got ${ITERATIONS})" >&2
  exit 2
fi

# Resolve sibling scripts relative to this file.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SINGLE_AVD="${script_dir}/run-single-avd-scenario.sh"
readonly START_STRFRY="${script_dir}/start-strfry.sh"
readonly STOP_STRFRY="${script_dir}/stop-strfry.sh"
# Secret-leak guard (Security Rule #6) — run over the preserved-evidence dir;
# see the call site for why it is scoped to the failing-iteration path.
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"

for dep in "${SINGLE_AVD}" "${START_STRFRY}" "${STOP_STRFRY}" "${SECRET_SCAN}"; do
  if [[ ! -f "${dep}" ]]; then
    echo "ERROR: required helper not found: ${dep}" >&2
    exit 1
  fi
done

readonly LOG_DIR="/tmp/flake-logs"
mkdir -p "${LOG_DIR}"

# Final relay teardown on ANY exit so nothing leaks past this script.
# Best-effort: stop-strfry.sh always exits 0, so it can't flip our rc.
cleanup() {
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Flake-stress: ${ITERATIONS} iteration(s) of ${TARGET}"
echo "Fail policy: the build fails if ANY single iteration fails."

declare -a FAILED_ITERS=()
passed=0

for (( i = 1; i <= ITERATIONS; i++ )); do
  echo
  echo "============================================================"
  echo "Iteration ${i}/${ITERATIONS}"
  echo "============================================================"

  # Per-iteration relay reset (isolation). Stop (idempotent) then
  # start fresh; start-strfry.sh wipes the data dir, so iteration i
  # always begins with an empty LMDB env.
  echo "[relay] resetting strfry for iteration ${i}"
  bash "${STOP_STRFRY}" || true
  bash "${START_STRFRY}"

  # Drive the target. run-single-avd-scenario.sh's exit code is the
  # `flutter drive` exit code (pipefail), so a failing iteration is a
  # real failure (a markTestSkipped is reported as a SKIP and exits 0).
  rc=0
  bash "${SINGLE_AVD}" "${TARGET}" || rc=$?

  if (( rc == 0 )); then
    echo "Iteration ${i}: PASS"
    passed=$(( passed + 1 ))
  else
    echo "Iteration ${i}: FAIL (rc=${rc})"
    FAILED_ITERS+=("${i}")
    # Preserve this iteration's evidence before the next one overwrites
    # the shared /tmp/*.log paths.
    cp /tmp/adb-logcat.log "${LOG_DIR}/iter-${i}.logcat.log" 2>/dev/null || true
    cp /tmp/flutter-drive.log "${LOG_DIR}/iter-${i}.drive.log" 2>/dev/null || true
  fi
done

echo
echo "============================================================"
echo "Flake-stress summary for ${TARGET}"
echo "  iterations: ${ITERATIONS}"
echo "  passed:     ${passed}"
echo "  failed:     ${#FAILED_ITERS[@]}"
echo "============================================================"

if (( ${#FAILED_ITERS[@]} > 0 )); then
  echo "  failed iterations: ${FAILED_ITERS[*]}"
  echo "  per-iteration logs saved under ${LOG_DIR}/iter-<n>.{logcat,drive}.log"
  echo
  # -------------------------------------------------------------------------
  # Secret-leak guard (Security Rule #6) over the preserved evidence.
  #
  # Scoped to the FAILING path on purpose, unlike the other orchestrators.
  # This lane copies logs into ${LOG_DIR} only inside the failed-iteration
  # branch above, so on an all-green run the directory is empty — and since
  # A4 an empty evidence directory is itself a failure verdict (rc=3), an
  # unconditional scan here would redden every clean stress run. That is not a
  # coverage hole: a green iteration is one where run-single-avd-scenario.sh
  # reached and passed its own scan of /tmp/adb-logcat.log and
  # /tmp/flutter-drive.log, because a leak there exits non-zero and would have
  # marked the iteration FAILED. The only logs this lane can publish unscanned
  # are the ones preserved from failing iterations, whose inner runner may have
  # died before its own scan — which is exactly what this call covers.
  #
  # No exit-code handling needed: this block already ends in `exit 1`, so the
  # scan can only add diagnosis, never rescue a run. Kept `|| scan_rc=$?` so
  # `set -e` cannot abort before the fail-rate summary is printed.
  # -------------------------------------------------------------------------
  echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
  scan_rc=0
  scan_dir_or_contain "${LOG_DIR}" || scan_rc=$?
  if (( scan_rc != 0 )); then
    echo "ERROR: secret-leak guard tripped on ${LOG_DIR} (rc=${scan_rc}) — see the" \
         "LEAK / UNUSABLE line(s) above. rc=1 means key material reached the" \
         "preserved logs; rc=3 means a failing iteration left no readable log." >&2
  fi
  echo
  # A flake test fails on ANY failure — even 1/N is a flake worth
  # surfacing. Report the observed fail rate for the run summary.
  fail_pct="$(awk -v f="${#FAILED_ITERS[@]}" -v t="${ITERATIONS}" \
    'BEGIN { printf "%.2f", (f/t)*100 }')"
  echo "ERROR: ${#FAILED_ITERS[@]}/${ITERATIONS} iteration(s) failed (${fail_pct}% fail rate)." >&2
  exit 1
fi

echo "All ${ITERATIONS} iteration(s) passed."
exit 0
