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

# The log-privacy gate (logscan_gate_dir): one implementation for every
# runner, sourced BEFORE the --self-test dispatch so the self-test exercises a
# runner wired exactly like the real one.
# shellcheck source=tooling/e2e/ci/logscan-gate.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/logscan-gate.sh"

# Where this runner's gate writes its findings report (sink:line, class, rule
# ids — never a value). Outside LOG_DIR, which the workflow uploads whole.
readonly LOGSCAN_REPORT="/tmp/logscan-report-flake-stress.ndjson"

# --self-test — hermetic: no device, no docker, no relay. Two things are under
# test. (1) CONTAINMENT: through logscan-gate.sh's floor arm with a FAKE
# scanner, a leak (rc 1) removes every *.log under the evidence directory and
# nothing else; rc 3 and rc 0 leave it untouched; the verdict comes back
# unchanged. (2) THE WIRING, read from this file: the gate library is sourced,
# the real call site hands LOG_DIR to logscan_gate_dir with the report outside
# it, and no soft `if [[ -x …` gate is in front of the scanner — an unbuilt
# scanner would be skipped, not fatal.
run_self_test() {
  local tmp fail=0 dir fake want rc real_run
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  fake="${tmp}/fake-scan.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'exit "${FAKE_SCAN_RC}"' > "${fake}"
  dir="${tmp}/logs"
  for want in 1 3 0; do
    rm -rf "${dir}"
    mkdir -p "${dir}/nested"
    printf 'a\n' > "${dir}/iter-3.logcat.log"
    printf 'b\n' > "${dir}/nested/drive.log"
    printf 'c\n' > "${dir}/notes.txt"
    rc=0
    HAVEN_LOGSCAN= SECRET_SCAN="${fake}" FAKE_SCAN_RC="${want}" \
      logscan_gate_dir host "${tmp}/needles" "${dir}" "${tmp}/report.ndjson" 2>/dev/null || rc=$?
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
    elif [[ ! -e "${dir}/iter-3.logcat.log" || ! -e "${dir}/nested/drive.log" ]]; then
      echo "SELF-TEST FAIL: scanner rc ${want} touched a directory it had no leak to contain" >&2
      fail=1
    fi
  done
  real_run="$(sed -n '1,/^run_self_test() {/p' "${BASH_SOURCE[0]}"; sed -n '/^if \[\[ "${1:-}" == "--self-test" \]\]; then/,$p' "${BASH_SOURCE[0]}")"
  real_run="$(grep -v '^[[:space:]]*#' <<<"${real_run}")"
  if ! grep -qE '^source .*/logscan-gate\.sh"$' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): logscan-gate.sh is no longer sourced" >&2
    fail=1
  fi
  if (( "$(grep -cE '^  logscan_gate_dir host /tmp/haven-soak/needles "\$\{LOG_DIR\}" "\$\{LOGSCAN_REPORT\}"' <<<"${real_run}")" != 1 )); then
    echo "SELF-TEST FAIL (wiring): expected exactly one gate call over LOG_DIR with the report outside it" >&2
    fail=1
  fi
  if grep -qE 'if[[:space:]]+\[\[[[:space:]]+-x[[:space:]]' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): a soft \`if [[ -x …\` scanner gate is in the real run" >&2
    fail=1
  fi
  if grep -qE '(^|[;&|][[:space:]]*)[[:space:]]*(cat|head|tail|less|more)[[:space:]]+[^|]*\.log' <<<"${real_run}"; then
    echo "SELF-TEST FAIL (wiring): this runner echoes a captured log itself; only the AVD runner may, after its gate" >&2
    fail=1
  fi
  if (( fail )); then
    echo "run-flake-stress.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-flake-stress.sh: self-test passed (the log-privacy gate removes exactly the *.log files it scanned on a leak and touches nothing on rc 3 or rc 0; the gate library is sourced, the one gate call covers LOG_DIR with its report outside the upload, no soft scanner gate, no captured-log echo of its own)."
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
# The key-material floor the gate's flag-off arm runs (logscan-gate.sh reads it
# at call time); the flag-on arm runs it through scan-logs.sh.
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
  # died before its own scan — which is exactly what this call covers. Each
  # file is typed by its name (logcat / drive) and scanned against the manifest
  # the first iteration's gate sealed for this run.
  #
  # No exit-code handling needed: this block already ends in `exit 1`, so the
  # scan can only add diagnosis, never rescue a run. Kept `|| scan_rc=$?` so
  # `set -e` cannot abort before the fail-rate summary is printed.
  # -------------------------------------------------------------------------
  echo "== Log-privacy gate over ${LOG_DIR} (Security Rules 6 and 15) =="
  scan_rc=0
  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}" "${LOGSCAN_REPORT}" || scan_rc=$?
  if (( scan_rc != 0 )); then
    echo "ERROR: log-privacy gate failed on ${LOG_DIR} (rc=${scan_rc}) — see the" \
         "line(s) above. rc=1 means key material or a declared identifier reached" \
         "the preserved logs; rc=3 means a failing iteration left no readable log." >&2
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
