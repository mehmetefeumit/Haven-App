#!/usr/bin/env bash
#
# Runs a coordinated two-AVD Haven E2E scenario. Alice's app runs on
# the action-booted emulator-5554; Bob's app runs on a sibling
# emulator (`bob_avd`) booted by this script on emulator-5556. The
# two processes coordinate exclusively via events on the hermetic
# strfry relay (no side channels).
#
# # Why a checked-in script
#
# The `reactivecircus/android-emulator-runner@v2` action executes
# inline `script:` blocks line-by-line under `sh -c`, breaking any
# script that relies on persisted shell state (cd, vars, background
# PIDs). Wrapping the whole flow in a single `bash <path>` invocation
# avoids that.
#
# # Architecture: serial-build, parallel-drive via flutter drive
#
# The naive approach — launching two `flutter test` invocations in
# parallel against the same source tree — fails on Gradle's
# `mergeDebugResources` task because both invocations write to the
# same `haven/build/app/intermediates/incremental/debug/` directory
# at once. A timing-based stagger (`sleep` between launches) cannot
# fix this: any sufficiently slow CI run pushes Alice's build past
# the stagger and into Bob's build window. We saw that fail with a
# 5 m+ build against a 120 s stagger.
#
# The race is on the filesystem, not on Gradle logic. The fix
# separates build (Gradle) from drive (test execution):
#
#   1. **Phase 1 — serial build** (`flutter build apk` x 2): produce
#      one APK per role with role-specific dart-defines. `HAVEN_E2E_ROLE`
#      is read in test code (compiled into the APK by `--target`), so
#      it must be baked at build time. Builds run serially against the
#      same Gradle project, so the intermediates directory is never
#      contended; the second build is fast because Gradle's
#      incremental + build cache short-circuits everything except the
#      dart-define delta.
#
#   2. **Phase 2 — parallel drive** (`flutter drive --use-application-binary`
#      x 2): each driver process installs its own APK on its own
#      device and runs the integration_test test via the VM service.
#      `--use-application-binary` skips Gradle entirely, so the two
#      processes never touch `haven/build/` after Phase 1 completes.
#      Coordination is exclusively via the shared strfry relay, which
#      mirrors production behavior.
#
# The driver wrapper at `haven/test_driver/integration_test.dart` is
# the standard `integrationDriver()` one-liner per the integration_test
# package docs.
#
# Usage:
#   bash tooling/e2e/ci/run-two-avd-scenario.sh <scenario-file>
#
# Required env:
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay.
#   ANDROID_HOME     Android SDK root (provided by the action).
#
# Side effects:
#   - Writes /tmp/{alice,bob}-test.log (per-role driver stdout).
#   - Writes /tmp/{alice,bob}-logcat.log (per-device logcat).
#   - Writes /tmp/bob-emulator.log (bob_avd emulator stderr).
#   - Writes /tmp/{alice,bob}.apk (pre-built per-role APKs).
#   - Spawns background processes; cleanup trap kills them on exit.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scenario-file>" >&2
  exit 2
fi

readonly SCENARIO_FILE="$1"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly ALICE_DEVICE="emulator-5554"
readonly BOB_DEVICE="emulator-5556"
readonly BOB_PORT="5556"
readonly BOB_AVD_NAME="bob_avd"
readonly ALICE_APK="/tmp/alice.apk"
readonly BOB_APK="/tmp/bob.apk"
readonly DRIVER_FILE="test_driver/integration_test.dart"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
readonly HAVEN_DIR="${repo_root}/haven"
readonly BUILD_APK="${HAVEN_DIR}/build/app/outputs/flutter-apk/app-debug.apk"

if [[ ! -f "${HAVEN_DIR}/pubspec.yaml" ]]; then
  echo "ERROR: Haven project not found at ${HAVEN_DIR}" >&2
  exit 1
fi

if [[ ! -f "${HAVEN_DIR}/${DRIVER_FILE}" ]]; then
  echo "ERROR: ${DRIVER_FILE} missing — required by flutter drive" >&2
  exit 1
fi

cd "${HAVEN_DIR}"

# -----------------------------------------------------------------
# Boot the secondary AVD (bob_avd) on port 5556.
# -----------------------------------------------------------------
echo "Starting ${BOB_AVD_NAME} on port ${BOB_PORT}..."
"${ANDROID_HOME}/emulator/emulator" \
  -avd "${BOB_AVD_NAME}" \
  -port "${BOB_PORT}" \
  -no-snapshot-save \
  -no-window \
  -gpu swiftshader_indirect \
  -noaudio \
  -no-boot-anim \
  -camera-back none \
  -memory 2048 \
  > /tmp/bob-emulator.log 2>&1 &
readonly BOB_EMU_PID=$!

# Wait for adbd inside bob_avd to come online, then for userspace
# boot to complete. Both adb commands are idempotent and safe to retry.
echo "Waiting for ${BOB_DEVICE} to come up..."
adb -s "${BOB_DEVICE}" wait-for-device
adb -s "${BOB_DEVICE}" shell \
  'while [[ -z $(getprop sys.boot_completed | tr -d "\r") ]]; do sleep 1; done'
adb -s "${BOB_DEVICE}" shell input keyevent 82  # unlock screen
echo "${BOB_DEVICE} booted."

# -----------------------------------------------------------------
# Capture per-device logcat for the failure-artifact step.
# -----------------------------------------------------------------
adb -s "${ALICE_DEVICE}" logcat -c
adb -s "${BOB_DEVICE}"   logcat -c
adb -s "${ALICE_DEVICE}" logcat -v threadtime > /tmp/alice-logcat.log &
readonly ALICE_LOGCAT_PID=$!
adb -s "${BOB_DEVICE}"   logcat -v threadtime > /tmp/bob-logcat.log &
readonly BOB_LOGCAT_PID=$!

cleanup() {
  for pid in "${ALICE_LOGCAT_PID}" "${BOB_LOGCAT_PID}" "${BOB_EMU_PID}"; do
    if kill -0 "${pid}" 2>/dev/null; then
      kill "${pid}" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

# -----------------------------------------------------------------
# Phase 1 — Build per-role APKs serially.
#
# Each build mutates `haven/build/app/intermediates/`, so running
# them in parallel races on `mergeDebugResources`. Serial is
# foolproof; Gradle's incremental + build cache make the second
# build cheap because only the dart-define delta changed.
# -----------------------------------------------------------------
echo "Phase 1/2 — Building Alice's APK..."
flutter build apk \
  --debug \
  --target="${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=alice
cp "${BUILD_APK}" "${ALICE_APK}"
echo "Phase 1/2 — Alice APK ready at ${ALICE_APK}"

echo "Phase 1/2 — Building Bob's APK..."
flutter build apk \
  --debug \
  --target="${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=bob
cp "${BUILD_APK}" "${BOB_APK}"
echo "Phase 1/2 — Bob APK ready at ${BOB_APK}"

# -----------------------------------------------------------------
# Phase 2 — Drive both via `flutter drive --use-application-binary`
# in parallel. Each driver installs its own APK on its own device
# (no shared state) and reports results back via the VM service.
# No Gradle work happens here.
#
# Dart-defines are deliberately NOT passed to `flutter drive` — they
# are read in test code that is compiled INTO the APK by Phase 1, so
# baking them at build time is sufficient. Adding them here would be
# misleading: they'd affect the driver wrapper (which doesn't read
# them) rather than the test code (which does).
# -----------------------------------------------------------------
echo "Phase 2/2 — Driving Alice on ${ALICE_DEVICE}..."
flutter drive \
  --device-id "${ALICE_DEVICE}" \
  --use-application-binary "${ALICE_APK}" \
  --driver "${DRIVER_FILE}" \
  --target "${SCENARIO_FILE}" \
  > /tmp/alice-test.log 2>&1 &
readonly ALICE_TEST_PID=$!

echo "Phase 2/2 — Driving Bob on ${BOB_DEVICE}..."
flutter drive \
  --device-id "${BOB_DEVICE}" \
  --use-application-binary "${BOB_APK}" \
  --driver "${DRIVER_FILE}" \
  --target "${SCENARIO_FILE}" \
  > /tmp/bob-test.log 2>&1 &
readonly BOB_TEST_PID=$!

# Wait for both drivers; capture each exit code independently.
# `set +e` so a non-zero from either `wait` doesn't abort the
# script before we've collected the second exit code.
set +e
wait "${ALICE_TEST_PID}"; alice_exit=$?
wait "${BOB_TEST_PID}";   bob_exit=$?
set -e

echo "===== Alice (${ALICE_DEVICE}) driver output ====="
cat /tmp/alice-test.log || true
echo "===== Bob (${BOB_DEVICE}) driver output ====="
cat /tmp/bob-test.log || true
echo "===== Exit codes: alice=${alice_exit} bob=${bob_exit} ====="

if [[ ${alice_exit} -ne 0 || ${bob_exit} -ne 0 ]]; then
  exit 1
fi
