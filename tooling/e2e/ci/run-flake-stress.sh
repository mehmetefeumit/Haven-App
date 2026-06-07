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

for dep in "${SINGLE_AVD}" "${START_STRFRY}" "${STOP_STRFRY}"; do
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
  # A flake test fails on ANY failure — even 1/N is a flake worth
  # surfacing. Report the observed fail rate for the run summary.
  fail_pct="$(awk -v f="${#FAILED_ITERS[@]}" -v t="${ITERATIONS}" \
    'BEGIN { printf "%.2f", (f/t)*100 }')"
  echo "ERROR: ${#FAILED_ITERS[@]}/${ITERATIONS} iteration(s) failed (${fail_pct}% fail rate)." >&2
  exit 1
fi

echo "All ${ITERATIONS} iteration(s) passed."
exit 0
