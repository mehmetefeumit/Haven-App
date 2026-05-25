#!/usr/bin/env bash
#
# Runs a coordinated two-AVD Haven E2E scenario. Alice's app runs on
# the action-booted emulator-5554; Bob's app runs on a sibling
# emulator (`bob_avd`) booted by this script on emulator-5556. The
# two processes coordinate exclusively via events on the hermetic
# strfry relay (no side channels).
#
# Why a checked-in script: see run-single-avd-scenario.sh for the
# full rationale. The reactivecircus action executes inline
# `script:` blocks line-by-line under `sh -c`, breaking any script
# that relies on persisted shell state (cd, vars, background PIDs).
#
# Usage:
#   bash tooling/e2e/ci/run-two-avd-scenario.sh <scenario-file>
#
# Required env:
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay.
#   ANDROID_HOME     Android SDK root (provided by the action).
#
# Optional env:
#   BUILD_STAGGER_SECONDS  Delay between Alice's and Bob's flutter
#                          test launches. Default 120; raise on slow
#                          CI to give the first APK build time to
#                          finish before the second one races on
#                          haven/build/.
#
# Side effects:
#   - Writes per-device logcat to /tmp/alice-logcat.log and
#     /tmp/bob-logcat.log.
#   - Writes per-role test stdout to /tmp/alice-test.log and
#     /tmp/bob-test.log.
#   - Writes the bob_avd emulator's stderr to /tmp/bob-emulator.log.
#   - Spawns three background processes; cleanup trap kills them.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scenario-file>" >&2
  exit 2
fi

readonly SCENARIO_FILE="$1"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly BUILD_STAGGER_SECONDS="${BUILD_STAGGER_SECONDS:-120}"
readonly ALICE_DEVICE="emulator-5554"
readonly BOB_DEVICE="emulator-5556"
readonly BOB_PORT="5556"
readonly BOB_AVD_NAME="bob_avd"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
readonly HAVEN_DIR="${repo_root}/haven"

if [[ ! -f "${HAVEN_DIR}/pubspec.yaml" ]]; then
  echo "ERROR: Haven project not found at ${HAVEN_DIR}" >&2
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

# Wait for adbd inside bob_avd to come online, then for the
# userspace boot to complete. Both adb commands are idempotent and
# safe to retry.
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
# Run Alice's flutter test in the background.
# -----------------------------------------------------------------
echo "Launching Alice on ${ALICE_DEVICE}..."
flutter test \
  --device-id "${ALICE_DEVICE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=alice \
  "${SCENARIO_FILE}" \
  > /tmp/alice-test.log 2>&1 &
readonly ALICE_TEST_PID=$!

# Stagger Bob's launch so Alice's APK build + install finishes
# before Bob's build starts. Both `flutter test` invocations write
# to the same haven/build/ directory; concurrent compilation would
# race on the APK output. Once the APKs are installed on their
# respective devices, the tests run truly in parallel — relay
# coordination is the synchronization primitive.
echo "Sleeping ${BUILD_STAGGER_SECONDS}s to serialize APK builds..."
sleep "${BUILD_STAGGER_SECONDS}"

echo "Launching Bob on ${BOB_DEVICE}..."
flutter test \
  --device-id "${BOB_DEVICE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=bob \
  "${SCENARIO_FILE}" \
  > /tmp/bob-test.log 2>&1 &
readonly BOB_TEST_PID=$!

# -----------------------------------------------------------------
# Wait for both invocations; capture each exit code independently.
# `set +e` so a non-zero from either `wait` doesn't abort the
# script before we've collected the second exit code.
# -----------------------------------------------------------------
set +e
wait "${ALICE_TEST_PID}"; alice_exit=$?
wait "${BOB_TEST_PID}";   bob_exit=$?
set -e

echo "===== Alice (${ALICE_DEVICE}) test output ====="
cat /tmp/alice-test.log || true
echo "===== Bob (${BOB_DEVICE}) test output ====="
cat /tmp/bob-test.log || true
echo "===== Exit codes: alice=${alice_exit} bob=${bob_exit} ====="

if [[ ${alice_exit} -ne 0 || ${bob_exit} -ne 0 ]]; then
  exit 1
fi
