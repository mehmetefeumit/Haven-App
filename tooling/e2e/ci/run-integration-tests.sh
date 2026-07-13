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
# rather than silently returning. A skipped test is reported as a
# SKIP by the Flutter test reporter and does NOT fail this script. We
# never convert "no keyring on this AVD" into a red build; we only fail
# on a genuine assertion failure / driver error.
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
# stalls across the six targets cannot approach this lane's own outer job
# timeout. The heavier single-target e2e_combined flow keeps the looser 300 s
# default baked into run-single-avd-scenario.sh.
export HAVEN_DRIVE_CONNECT_WATCHDOG_SECS="${HAVEN_DRIVE_CONNECT_WATCHDOG_SECS:-120}"

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

for dep in "${SINGLE_AVD}" "${START_STRFRY}" "${STOP_STRFRY}"; do
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
  # error fails here; a `markTestSkipped` is reported as a SKIP by the
  # Flutter reporter and exits 0 (honest skip, not a failure).
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

echo "All integration targets passed (skips, if any, are honest)."
exit 0
