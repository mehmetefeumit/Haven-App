#!/usr/bin/env bash
#
# Runs the Haven non-E2E Flutter integration tests (the five that used
# to be "orphans" — present in haven/integration_test/ but driven by
# NOTHING in CI, so they reported green while never running) on the
# action-booted emulator-5554, ONE target at a time, with a fresh
# hermetic strfry relay per target (backlog CI-4).
#
# These are distinct from the consolidated functional flow
# (`integration_test/e2e/e2e_combined.dart`, driven by the e2e_android
# job). They exercise the real Rust FFI directly:
#
#   integration_test/app_test.dart                       (AppRouter gate)
#   integration_test/encryption_pipeline_test.dart       (enc→dec round-trip)
#   integration_test/circle_service_remove_member_test.dart
#   integration_test/circle_admin_leave_ghost_test.dart
#   integration_test/keyring_test.dart
#
# # Keyring-dependent tests are an HONEST SKIP, not a failure
#
# Several of these construct `CircleManagerFfi`, which calls
# `init_keyring_store()`. On a headless AVD without a Secret Service /
# Keychain that would normally fail — but the bootstrap installs the
# in-memory keyring (`useInMemoryKeyringForTest`) where it can, and any
# test that still can't get a keyring calls `markTestSkipped(...)`
# rather than silently returning. Such a skip is NOT visible as a skip:
# `Result.skipped` satisfies `isPassing`, so the on-device reporter
# files it under `passed` and `integrationDriver()` exits 0. It is
# caught instead by matching the reason text in the drive log, and a
# hatch that fires now FAILS this script — every one of them is argued
# unreachable in `tooling/e2e/expected_drive_skips.txt`, so firing is a
# broken precondition, not an honest skip.
#
# # Per-target relay reset (isolation)
#
# Each target gets a freshly wiped strfry (stop-strfry.sh +
# start-strfry.sh) BEFORE it runs. The deterministic per-actor seeds
# used by these tests are byte-identical across runs, so leftover
# events from a previous target would be served back as stale state.
# A clean relay per target guarantees order-independence: the suite
# passes (or fails) the same way regardless of which target ran first.
#
# # Why pre-built APKs are passed in (the OOM trap)
#
# `flutter build apk` peaks at several GB (Rust-NDK + Gradle). Building
# WHILE the emulator + strfry container are resident is the historical
# cause of the silently-lost runner (see docs/E2E_TROUBLESHOOTING.md).
# So — exactly like the e2e_android job — the workflow builds every
# target's APK in a dedicated step BEFORE the emulator boots and passes
# the staged path in here. This script then only stages each APK at the
# path `run-single-avd-scenario.sh` expects (/tmp/scenario.apk) and
# drives it; no Gradle runs while the emulator is up.
#
# For LOCAL runs you may omit the `=<apk>` part of an argument; this
# script then removes any stale /tmp/scenario.apk so
# run-single-avd-scenario.sh falls back to building that target itself.
#
# # Why a checked-in script
#
# The reactivecircus/android-emulator-runner action runs each line of a
# multi-line `script:` in a separate `sh -c`, dropping shell state
# (cd, vars, background PIDs). Wrapping the whole loop in one
# `bash <path>` invocation keeps state coherent — same rationale as the
# other tooling/e2e/ci scripts.
#
# Usage:
#   bash tooling/e2e/ci/run-integration-tests.sh \
#     <target.dart>[=<prebuilt.apk>] [<target.dart>[=<prebuilt.apk>] ...]
#
# Example (CI, pre-built APKs):
#   bash tooling/e2e/ci/run-integration-tests.sh \
#     integration_test/app_test.dart=/tmp/integration-apks/app_test.apk \
#     integration_test/keyring_test.dart=/tmp/integration-apks/keyring_test.apk
#
# Example (local, build-on-demand):
#   bash tooling/e2e/ci/run-integration-tests.sh \
#     integration_test/app_test.dart integration_test/keyring_test.dart
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay (e.g.
#                    ws://10.0.2.2:7777 — host-loopback alias from
#                    inside the emulator). Passed through to
#                    run-single-avd-scenario.sh.
#
# Optional env (forwarded to start-strfry.sh / stop-strfry.sh):
#   STRFRY_IMAGE, STRFRY_DATA_DIR, STRFRY_CONTAINER, STRFRY_PORT,
#   STRFRY_READY_TIMEOUT  — see start-strfry.sh.
#
# Side effects:
#   - Per target, overwrites /tmp/adb-logcat.log and
#     /tmp/flutter-drive.log (run-single-avd-scenario.sh), then copies
#     them to /tmp/integration-logs/<target>.{logcat,drive}.log so a
#     later target can't clobber an earlier failure's evidence.
#   - Resets the strfry container + its data dir between targets.

set -euo pipefail

# Per-target `flutter drive` timeout, exported so run-single-avd-scenario.sh
# (invoked by run_one for each target) bounds every drive. These targets are
# small and fast — seconds each — so 10m is a generous ceiling that still lets
# a single hung drive fail fast and leaves room for the remaining targets,
# instead of one hang consuming the whole 45-min job (the historical failure:
# a leaked foreground service wedged keyring_test's request_data handshake).
# Overridable from the environment; the heavier single-target e2e_combined
# flow keeps the looser default baked into run-single-avd-scenario.sh.
export HAVEN_DRIVE_TIMEOUT="${HAVEN_DRIVE_TIMEOUT:-10m}"

# Tighten run-single-avd-scenario.sh's connect-phase watchdog for this lane.
# These pure-FFI targets mount no heavy UI and connect to the driver in well
# under 30 s, so a 120 s watchdog is ample headroom yet bounds the per-target
# cost of a pre-connect stall (retried up to DRIVE_MAX_ATTEMPTS) so several
# stalls across the lane's targets cannot approach its own outer job
# timeout. The heavier single-target e2e_combined flow keeps the looser 300 s
# default baked into run-single-avd-scenario.sh.
export HAVEN_DRIVE_CONNECT_WATCHDOG_SECS="${HAVEN_DRIVE_CONNECT_WATCHDOG_SECS:-120}"

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
    echo "run-integration-tests.sh: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-integration-tests.sh: self-test passed (the secret-leak gate removes exactly the *.log files it scanned on a leak, leaves a labels-only LEAK.marker, and touches nothing on rc 3 or rc 0)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <target.dart>[=<prebuilt.apk>] [<target.dart>[=<prebuilt.apk>] ...]" >&2
  exit 2
fi

# Resolve sibling scripts relative to this file so the workflow doesn't
# have to care about its cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SINGLE_AVD="${script_dir}/run-single-avd-scenario.sh"
readonly START_STRFRY="${script_dir}/start-strfry.sh"
readonly STOP_STRFRY="${script_dir}/stop-strfry.sh"
# Secret-leak guard (Security Rule #6) — run over the aggregated evidence dir
# after every target; see the call site for why the inner runner's own scan is
# not sufficient here.
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"

for dep in "${SINGLE_AVD}" "${START_STRFRY}" "${STOP_STRFRY}" "${SECRET_SCAN}"; do
  if [[ ! -f "${dep}" ]]; then
    echo "ERROR: required helper not found: ${dep}" >&2
    exit 1
  fi
done

readonly STAGED_APK="/tmp/scenario.apk"
readonly LOG_DIR="/tmp/integration-logs"
mkdir -p "${LOG_DIR}"

# Tear the relay down on ANY exit (pass, fail, or signal) so we never
# leak a container/data dir into a later step or a reused runner. The
# per-target loop also stops the relay before each start, so this trap
# is the final backstop. stop-strfry.sh is best-effort (always exits
# 0), so it can't itself flip the script's exit code.
cleanup() {
  bash "${STOP_STRFRY}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# A filesystem-safe slug for a target path, used to name per-target log
# copies (integration_test/app_test.dart -> integration_test_app_test_dart).
slug() {
  printf '%s' "$1" | tr '/.' '__'
}

declare -a PASSED=()
declare -a FAILED=()
declare -a SKIPPED_BUILD=()

run_one() {
  local spec="$1"
  local target apk

  # Split "<target>=<apk>" (apk optional). A target path never contains
  # '=', so the first '=' is an unambiguous delimiter.
  if [[ "${spec}" == *"="* ]]; then
    target="${spec%%=*}"
    apk="${spec#*=}"
  else
    target="${spec}"
    apk=""
  fi

  if [[ -z "${target}" ]]; then
    echo "ERROR: empty target in argument '${spec}'" >&2
    # Record as a failure so a malformed argument fails the build
    # rather than being silently swallowed by the caller's `|| true`.
    FAILED+=("<empty-target:${spec}>")
    return 2
  fi

  echo "============================================================"
  echo "Integration target: ${target}"
  echo "  prebuilt APK: ${apk:-<none — run-single-avd-scenario.sh will build>}"
  echo "============================================================"

  # --- Per-target relay reset (isolation) -------------------------
  # Stop first (idempotent), then start fresh. start-strfry.sh wipes
  # the data dir on start, so this guarantees an empty LMDB env for
  # every target regardless of what the previous target published.
  echo "[relay] resetting strfry for ${target}"
  bash "${STOP_STRFRY}" || true
  bash "${START_STRFRY}"

  # --- Stage the APK at the path run-single-avd-scenario.sh expects.
  # If a prebuilt APK was supplied, copy it into place (it would
  # otherwise reuse whatever stale APK a previous target left there).
  # If none was supplied (local use), remove any stale staged APK so
  # run-single-avd-scenario.sh rebuilds for THIS target.
  if [[ -n "${apk}" ]]; then
    if [[ ! -f "${apk}" ]]; then
      echo "ERROR: prebuilt APK for ${target} not found at ${apk}" >&2
      # A misconfigured/missing prebuilt APK is a real failure (the
      # workflow's build step should have produced it) — record it so
      # the build fails instead of the caller's `|| true` hiding it.
      FAILED+=("${target}")
      return 1
    fi
    cp "${apk}" "${STAGED_APK}"
    echo "[apk] staged ${apk} -> ${STAGED_APK}"
  else
    rm -f "${STAGED_APK}"
    SKIPPED_BUILD+=("${target}")
    echo "[apk] no prebuilt APK; run-single-avd-scenario.sh will build ${target}"
  fi

  # --- Drive the target. run-single-avd-scenario.sh installs, grants
  # runtime permissions, and runs `flutter drive`. Its exit code is
  # flutter drive's (pipefail), so a genuine assertion failure / driver
  # error fails here. A `markTestSkipped` exits 0 on its own (the
  # reporter counts it as passed), so the scenario's drive-log check is
  # what turns a fired hatch red — see `expected_drive_skips.txt`.
  local rc=0
  bash "${SINGLE_AVD}" "${target}" || rc=$?

  # --- Preserve this target's evidence before the next target
  # overwrites the shared /tmp/*.log paths.
  local s
  s="$(slug "${target}")"
  cp /tmp/adb-logcat.log "${LOG_DIR}/${s}.logcat.log" 2>/dev/null || true
  cp /tmp/flutter-drive.log "${LOG_DIR}/${s}.drive.log" 2>/dev/null || true

  if (( rc == 0 )); then
    echo "PASS: ${target}"
    PASSED+=("${target}")
  else
    echo "FAIL (rc=${rc}): ${target}"
    FAILED+=("${target}")
  fi
}

for spec in "$@"; do
  # Do NOT abort the whole suite on the first failing target — run them
  # all so one red target doesn't mask a second. We aggregate and fail
  # at the end if ANY target failed. `set -e` is intentionally not in
  # effect for the per-target call (run_one captures rc itself).
  run_one "${spec}" || true
done

# ---------------------------------------------------------------------------
# Secret-leak guard (Security Rule #6) over the AGGREGATED evidence directory.
#
# run-single-avd-scenario.sh already scans /tmp/adb-logcat.log and
# /tmp/flutter-drive.log after each drive — but only when it REACHES that scan.
# It runs under `set -e` from the moment it starts logcat, and has two earlier
# `exit 2` argument guards, so an install / build / config failure leaves the
# lane through a path that never scans. run_one's `cp` then copies those
# never-scanned logs into ${LOG_DIR}, which the workflow uploads with 14-day
# retention — i.e. the failure mode publishes precisely the material the inner
# guard exists to catch. Re-scanning the aggregate closes that window.
#
# Deliberately placed BEFORE the summary's `exit 1` so it also runs on red
# runs: those are exactly the runs where the inner scan was likely skipped.
# The verdict is applied after the FAIL list is printed, so a leak never robs
# triage of the failing-target names (both outcomes are exit 1 regardless).
# ---------------------------------------------------------------------------
echo
echo "== Secret-leak scan over ${LOG_DIR} (Security Rule 6) =="
scan_rc=0
scan_dir_or_contain "${LOG_DIR}" || scan_rc=$?

echo
echo "============================================================"
echo "Integration test summary"
echo "  passed:  ${#PASSED[@]}"
echo "  failed:  ${#FAILED[@]}"
echo "============================================================"
if (( ${#PASSED[@]} > 0 )); then
  printf '  PASS  %s\n' "${PASSED[@]}"
fi
if (( ${#SKIPPED_BUILD[@]} > 0 )); then
  echo "  (built on-demand, no prebuilt APK: ${#SKIPPED_BUILD[@]})"
fi
if (( ${#FAILED[@]} > 0 )); then
  printf '  FAIL  %s\n' "${FAILED[@]}"
  echo
  echo "ERROR: ${#FAILED[@]} integration target(s) failed." >&2
  exit 1
fi

if (( scan_rc != 0 )); then
  echo "ERROR: secret-leak guard tripped on ${LOG_DIR} (rc=${scan_rc}) — see the" \
       "LEAK / UNUSABLE line(s) above. rc=1 means key material reached the logs;" \
       "rc=3 means a target's log was absent, unreadable or empty, so this run" \
       "carries no evidence either way." >&2
  exit 1
fi

echo "All integration targets passed (skips, if any, are honest)."
exit 0
