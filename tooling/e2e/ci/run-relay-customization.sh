#!/usr/bin/env bash
#
# Drives Haven's relay-CUSTOMIZATION Flutter integration tests on the
# action-booted emulator-5554, ONE target at a time, against TWO
# hermetic strfry relays (the relay-customization CI lane).
#
# This is the two-relay sibling of run-integration-tests.sh. The three
# targets it drives:
#
#   integration_test/relay_customization_publish_test.dart   (service-FFI wire proofs)
#   integration_test/relay_customization_trigger_test.dart   (provider bug-catcher)
#   integration_test/relay_resync_convergence_test.dart      (MIP-01 relay-update convergence)
#   integration_test/relay_two_plane_privacy_test.dart       (two-plane no-leak proof)
#
# # Why TWO relays
#
# These tests prove that when a user CUSTOMIZES their relay set, Haven
# actually honors the customization — events land on the chosen relay
# and NOT (only) on the default. A single relay cannot prove that: if
# there is only one relay, "published to the custom relay" and
# "published to the default relay" are indistinguishable. So the lane
# runs a SECOND, DISTINCT relay (R2) that stands in for the custom
# relay, distinct from R1 (the default). The targets read two
# dart-defines baked at build time:
#
#   HAVEN_E2E_RELAY    R1 = ws://10.0.2.2:7777  (the default relay)
#   HAVEN_E2E_RELAY_2  R2 = ws://10.0.2.2:7778  (the custom relay)
#
# `flutter drive` does NOT re-pass dart-defines, so both values are
# compiled into each APK by the workflow's pre-emulator build step;
# this driver only resets relays, stages the prebuilt APK, and drives.
#
# # Two relays => distinct container / port / data-dir
#
# start-strfry.sh / stop-strfry.sh manage exactly ONE relay each, keyed
# by STRFRY_CONTAINER / STRFRY_PORT / STRFRY_DATA_DIR. Their defaults
# are the R1 relay: container `strfry`, port `7777`, data dir
# `/tmp/strfry-data`. CRITICALLY, start-strfry.sh `docker rm -f`s its
# own container name on start and `rm -rf`s its own DATA_DIR — so if R2
# reused R1's name/port/dir, starting R2 would KILL R1 and wipe its
# LMDB env. R2 therefore MUST use a distinct identity:
#
#   STRFRY_CONTAINER=strfry2  STRFRY_PORT=7778  STRFRY_DATA_DIR=/tmp/strfry2-data
#
# # Per-target reset of BOTH relays (isolation)
#
# The integration targets use deterministic per-actor seeds (Alice
# [0x01;32], Bob [0x02;32], Carol [0x03;32]); their events are
# byte-for-byte identical every run. Leftover events from a prior
# target — on EITHER relay — would be served back as stale state and
# poison the next target. So before each target we reset BOTH relays
# (stop + start, which wipes both LMDB envs), guaranteeing
# order-independence: the suite passes (or fails) the same way
# regardless of which target ran first.
#
# # Why pre-built APKs are passed in (the OOM trap)
#
# `flutter build apk` peaks at several GB (Rust-NDK + Gradle). Building
# WHILE the emulator + two strfry containers are resident is the
# historical cause of the silently-lost runner (see
# docs/E2E_TROUBLESHOOTING.md). So — exactly like the e2e_android and
# e2e_integration lanes — the workflow builds every target's APK in a
# dedicated step BEFORE the emulator boots and passes the staged path
# in here. This script then only stages each APK at the path
# run-single-avd-scenario.sh expects (/tmp/scenario.apk) and drives it;
# no Gradle runs while the emulator is up.
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
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     <target.dart>[=<prebuilt.apk>] [<target.dart>[=<prebuilt.apk>] ...]
#
# Example (CI, pre-built APKs):
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     integration_test/relay_customization_publish_test.dart=/tmp/relay-custom-apks/relay_customization_publish_test.apk \
#     integration_test/relay_customization_trigger_test.dart=/tmp/relay-custom-apks/relay_customization_trigger_test.apk \
#     integration_test/relay_resync_convergence_test.dart=/tmp/relay-custom-apks/relay_resync_convergence_test.apk
#
# Example (local, build-on-demand):
#   bash tooling/e2e/ci/run-relay-customization.sh \
#     integration_test/relay_customization_publish_test.dart \
#     integration_test/relay_customization_trigger_test.dart \
#     integration_test/relay_resync_convergence_test.dart
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY    R1 WebSocket URL (default: ws://10.0.2.2:7777),
#                      forwarded to run-single-avd-scenario.sh.
#   HAVEN_E2E_RELAY_2  R2 WebSocket URL (default: ws://10.0.2.2:7778) —
#                      informational here (baked into the APK at build
#                      time), kept for parity / local invocation.
#
# Optional env (forwarded to start-strfry.sh / stop-strfry.sh for R1):
#   STRFRY_IMAGE, STRFRY_READY_TIMEOUT  — see start-strfry.sh. R2 always
#                      uses its own fixed container/port/data-dir below.
#
# Side effects:
#   - Per target, overwrites /tmp/adb-logcat.log and
#     /tmp/flutter-drive.log (run-single-avd-scenario.sh), then copies
#     them to /tmp/relay-custom-logs/<slug>.{logcat,drive}.log so a
#     later target can't clobber an earlier failure's evidence.
#   - Resets BOTH strfry containers + their data dirs between targets.

set -euo pipefail

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

# R2's distinct identity. start-strfry.sh defaults R1 to
# strfry/7777/tmp/strfry-data; R2 MUST differ on all three so the R2
# start can't `docker rm -f` R1's container or `rm -rf` R1's data dir.
readonly R2_CONTAINER="strfry2"
readonly R2_PORT="7778"
readonly R2_DATA_DIR="/tmp/strfry2-data"

readonly STAGED_APK="/tmp/scenario.apk"
readonly LOG_DIR="/tmp/relay-custom-logs"
mkdir -p "${LOG_DIR}"

# Start/stop helpers for each relay. R1 uses the script defaults; R2
# overrides container/port/data-dir via env. STRFRY_IMAGE /
# STRFRY_READY_TIMEOUT (if set in the environment) flow through to both
# because start-strfry.sh reads them from the environment.
start_r1() { bash "${START_STRFRY}"; }
stop_r1()  { bash "${STOP_STRFRY}"; }
start_r2() {
  STRFRY_CONTAINER="${R2_CONTAINER}" \
  STRFRY_PORT="${R2_PORT}" \
  STRFRY_DATA_DIR="${R2_DATA_DIR}" \
    bash "${START_STRFRY}"
}
stop_r2() {
  STRFRY_CONTAINER="${R2_CONTAINER}" \
  STRFRY_DATA_DIR="${R2_DATA_DIR}" \
    bash "${STOP_STRFRY}"
}

# Tear down BOTH relays on ANY exit (pass, fail, or signal) so we never
# leak a container/data dir into a later step or a reused runner. The
# per-target loop also resets the relays before each target, so this
# trap is the final backstop. Each teardown is best-effort (`|| true`)
# so cleanup can't itself flip the script's exit code, and so a failed
# R1 stop doesn't skip the R2 stop.
cleanup() {
  stop_r1 >/dev/null 2>&1 || true
  stop_r2 >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Reset BOTH relays for per-target isolation: stop each (idempotent),
# then start each fresh. start-strfry.sh wipes the data dir on start,
# so this guarantees an empty LMDB env on BOTH relays for every target
# regardless of what the previous target published to either one.
reset_relays() {
  echo "[relay] resetting R1 (${STRFRY_CONTAINER:-strfry}) and R2 (${R2_CONTAINER})"
  stop_r1 || true
  stop_r2 || true
  start_r1
  start_r2
}

# A filesystem-safe slug for a target path, used to name per-target log
# copies (integration_test/foo.dart -> integration_test_foo_dart).
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
  echo "Relay-customization target: ${target}"
  echo "  prebuilt APK: ${apk:-<none — run-single-avd-scenario.sh will build>}"
  echo "============================================================"

  # --- Per-target reset of BOTH relays (isolation) ----------------
  # Wipe both LMDB envs BEFORE this target so deterministic-seed,
  # byte-identical events published by a prior target (on EITHER relay)
  # can't be served back as stale state and poison this one.
  reset_relays

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
  # Flutter reporter and exits 0 (honest skip, not a failure). Only R1
  # (HAVEN_E2E_RELAY) is forwarded as env — R2 was baked into the APK
  # at build time; the drive step never re-passes dart-defines.
  local rc=0
  HAVEN_E2E_RELAY="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}" \
    bash "${SINGLE_AVD}" "${target}" || rc=$?

  # Retry ONCE on a per-drive TIMEOUT only (rc=124). The first target in the
  # loop cold-attaches a snapshot-restored emulator, where `flutter drive`'s
  # VM-service attach can non-deterministically wedge until the per-drive
  # timeout even though the test body itself runs clean in <1 min (observed:
  # the publish target stalling 20 min with an empty log, then all tests
  # flushing at kill time). This is an attach/infra flake, NOT a test bug —
  # so retry exactly once after force-stopping any wedged app so the
  # re-attach is clean and hits a now-warm emulator. A REAL assertion/driver
  # failure exits with a deterministic NON-124 rc and is never retried, so a
  # genuine red never gets a second chance to flake green.
  if (( rc == 124 )); then
    echo "WARN: ${target} hit the per-drive timeout (rc=124) — likely a" \
      "cold-attach flake; force-stopping and retrying once."
    adb -s emulator-5554 shell am force-stop com.oblivioustech.haven || true
    rc=0
    HAVEN_E2E_RELAY="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}" \
      bash "${SINGLE_AVD}" "${target}" || rc=$?
  fi

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
echo "Relay-customization test summary"
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
  echo "ERROR: ${#FAILED[@]} relay-customization target(s) failed." >&2
  exit 1
fi

echo "All relay-customization targets passed (skips, if any, are honest)."
exit 0
