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
  # The lane's floor reaches the manifest only if the pre-seal runs before any
  # gate does — and the first gate here is the INNER runner's, inside iteration
  # 1 — so the pre-seal has to precede the loop. Pinned against the EXIT trap,
  # which is armed between the two.
  local seal_line trap_line
  seal_line="$(grep -n -m1 '^logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA\[@\]}" || seal_rc=$?$' "${BASH_SOURCE[0]}" || true)"
  seal_line="${seal_line%%:*}"
  trap_line="$(grep -n -m1 '^trap cleanup EXIT$' "${BASH_SOURCE[0]}" || true)"
  trap_line="${trap_line%%:*}"
  if [[ -z "${seal_line}" || -z "${trap_line}" ]] || (( seal_line > trap_line )) \
     || ! grep -qE '^readonly -a SEAL_EXTRA=\(--floor relay=7\)$' "${BASH_SOURCE[0]}"; then
    echo "SELF-TEST FAIL (wiring): the lane's manifest must be sealed once, with its relay floor, before the EXIT trap is armed (seal='${seal_line:-none}', trap='${trap_line:-none}')" >&2
    fail=1
  fi
  # The relay log is only evidence if it is read out of a LIVE container and
  # written where the gate still reaches it: after the iteration's own relay
  # reset (so it is this iteration's relay), inside the failed-iteration branch
  # beside the logcat and drive copies (so a green run still leaves LOG_DIR
  # empty and nothing uploads unscanned), and exactly once. The name is checked
  # through the walker's own predicate, so a change to the relay-name list
  # fails here rather than silently retyping the dump as a `diag` sink, where
  # the structural rules would read a relay's legitimate pubkeys and event ids
  # as leaks.
  local reset_line dump_line gate_line
  reset_line="$(grep -n -m1 '^  bash "${START_STRFRY}"$' "${BASH_SOURCE[0]}" || true)"
  reset_line="${reset_line%%:*}"
  dump_line="$(grep -n -m1 '^    docker logs "${STRFRY_CONTAINER:-strfry}" > "${LOG_DIR}/strfry\.iter-${i}\.log" 2>&1 || true$' "${BASH_SOURCE[0]}" || true)"
  dump_line="${dump_line%%:*}"
  gate_line="$(grep -n -m1 '^  logscan_gate_dir host /tmp/haven-soak/needles "${LOG_DIR}"' "${BASH_SOURCE[0]}" || true)"
  gate_line="${gate_line%%:*}"
  if [[ -z "${reset_line}" || -z "${dump_line}" || -z "${gate_line}" ]] \
     || (( reset_line > dump_line || dump_line > gate_line )) \
     || (( "$(grep -cE '^[[:space:]]*docker logs ' <<<"${real_run}")" != 1 )) \
     || (( "$(grep -cE '^    (cp /tmp/(adb-logcat|flutter-drive)\.log|docker logs )' <<<"${real_run}")" != 3 )) \
     || ! logscan_is_relay_log "strfry.iter-3.log"; then
    echo "SELF-TEST FAIL (wiring): the relay log must be dumped from the live container exactly once, after the iteration's relay reset (line ${reset_line:-none}) and before the gate (line ${gate_line:-none}), beside the failed iteration's logcat and drive copies, under a name logscan_gate_dir types as a relay sink (dump line ${dump_line:-none})" >&2
    fail=1
  fi
  if (( fail )); then
    echo "run-flake-stress.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-flake-stress.sh: self-test passed (the log-privacy gate removes exactly the *.log files it scanned on a leak and touches nothing on rc 3 or rc 0; the gate library is sourced, the one gate call covers LOG_DIR with its report outside the upload, no soft scanner gate, no captured-log echo of its own, the manifest is sealed once with the lane's relay floor before the trap is armed, and each failed iteration's relay log is dumped from the live container beside its logcat and drive copies, typed as a relay sink)."
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

# The line floor this lane seals with. A floor is what turns "the scan read an
# empty or truncated file and found nothing" into rc 4 instead of a green, so
# it is calibrated to the smallest COMPLETE capture this lane produces and
# never to what would make it pass.
#
# relay=7. The policy's 1 is sized for the hermetic host relay, which prints a
# single listen line; this lane's relay is strfry, whose `docker logs` dump is
# 14-23 lines for a full run across the fleet, of which the first 9 are a fixed
# startup block. 7 is half the smallest complete dump, so a dump below it is
# truncated or absent — which is what a container torn down before the dump
# looks like: ONE line of docker error text. The drive and logcat floors stay
# the policy's: every iteration drives the whole core flow onto a device-wide
# capture, which is exactly the shape those defaults were sized for.
#
# Sealed ONCE, before the first iteration: every gate reuses the manifest at
# the out path, and the first one to run is the INNER runner's, inside
# iteration 1 — so without this the lane's manifest would carry the policy
# defaults and this floor would never exist.
readonly -a SEAL_EXTRA=(--floor relay=7)
seal_rc=0
logscan_seal host /tmp/haven-soak/needles "${SEAL_EXTRA[@]}" || seal_rc=$?
if (( seal_rc != 0 )); then
  echo "ERROR: could not seal this lane's needle manifest (rc ${seal_rc}) — see the" \
       "line(s) above; every gate would fail the same way, so nothing this run" \
       "captures can be proven clean." >&2
  exit 1
fi

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
    # The relay's OWN log, read out of the container while it still exists.
    # `docker logs` against a torn-down container prints one line of error
    # text, and that is exactly what the workflow's post-run collection step
    # uploaded under this lane's relay name for as long as it existed: this
    # script's EXIT trap `docker rm -f`s the container before any later step
    # runs, so the relay sink this lane certified was a docker error message,
    # not a relay log. Here the container is still up — the next reset is the
    # first thing the NEXT iteration does.
    # In the FAILED branch with the other two, deliberately: this lane keeps
    # evidence only for iterations that failed (an all-green run leaves
    # LOG_DIR empty, which is what keeps the gate below off a clean run), and
    # a file outside the branch would be uploaded with nothing scanning it.
    # The name must LEAD with `strfry` (logscan_gate_dir types `strfry*.log`
    # as a `relay` sink: structural rules off, the public classes scoped out)
    # and must contain neither `logcat` nor `drive`, which the walker matches
    # first.
    docker logs "${STRFRY_CONTAINER:-strfry}" > "${LOG_DIR}/strfry.iter-${i}.log" 2>&1 || true
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
         "the preserved logs; rc=3 means a failing iteration left no readable log;" \
         "rc=4 means one is below its line floor, which on THIS path is usually" \
         "the failure itself — an iteration that died early leaves a short" \
         "transcript. Diagnosis only: this block already exits 1." >&2
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
