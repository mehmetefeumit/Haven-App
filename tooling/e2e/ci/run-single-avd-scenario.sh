#!/usr/bin/env bash
#
# Runs a single-AVD Haven E2E scenario on the action-booted
# emulator-5554.
#
# The consolidated `e2e_combined.dart` test is designed for this
# harness: Alice runs through the production UI on the AVD; Bob and
# Carol participate as in-process `SyntheticUser` instances driven
# directly via the Rust FFI. There is no multi-AVD coordination,
# no swap tuning, and no parallel `flutter drive` orchestration.
#
# Phase 1 — `flutter build apk`     (bake the test APK once)
# Phase 2 — `adb install`           (install on the device)
# Phase 3 — `adb shell pm grant`    (pre-grant runtime permissions)
# Phase 4 — `flutter drive --use-application-binary`
#                                   (no Gradle, runs the test)
#
# # Why this is more than `flutter test`
#
# `flutter test integration_test/foo.dart` builds + installs +
# drives in a single command, but it gives no opportunity to
# pre-grant runtime permissions before the production UI requests
# them. Android 12+ shows the location permission dialog modally
# on top of Haven; the integration_test runner cannot dismiss it,
# and any test that interacts with the UI after that point fails
# because all taps land on the dialog instead of Haven. Splitting
# the lifecycle lets `adb shell pm grant` slot between `adb
# install` and the first frame, which suppresses the dialog
# entirely. The same trick is the canonical pattern for Flutter
# integration tests on Firebase Test Lab and similar CI harnesses.
#
# # Why a checked-in script
#
# The `reactivecircus/android-emulator-runner@v2` action executes
# inline `script:` blocks line-by-line under `sh -c`, breaking any
# script that relies on persisted shell state (cd, vars, background
# PIDs). Wrapping the entire flow in a single `bash <path>`
# invocation avoids that.
#
# Usage:
#   bash tooling/e2e/ci/run-single-avd-scenario.sh <scenario-file>
#
# Required env (set by the workflow before invoking this script):
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay (e.g.
#                    ws://10.0.2.2:7777 — host loopback alias from
#                    inside the emulator).
#
# Side effects:
#   - Writes /tmp/adb-logcat.log (uploaded as a CI failure artifact).
#   - Writes /tmp/scenario.apk (the per-scenario debug APK).
#   - Spawns a logcat tee process; cleanup trap kills it on exit.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scenario-file>" >&2
  exit 2
fi

readonly SCENARIO_FILE="$1"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"
readonly DEVICE="emulator-5554"
readonly APK="/tmp/scenario.apk"
readonly DRIVER_FILE="test_driver/integration_test.dart"

# Resolve the haven/ project directory relative to this script's
# location so the workflow doesn't have to care about its cwd.
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
# Logcat capture — runs from the moment we have a device until the
# script exits. The trap below kills it cleanly so the file is
# flushed for the failure-artifact upload step.
# -----------------------------------------------------------------
adb logcat -c
adb logcat -v threadtime > /tmp/adb-logcat.log &
readonly LOGCAT_PID=$!

cleanup() {
  if kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------
# Phase 1 — Build the APK once with the production main entry point
# replaced by the integration-test entry point (`--target`). The
# resulting APK contains both the production app code and the
# scenario's test code, so `flutter drive --use-application-binary`
# can install + drive it without any further Gradle work.
# -----------------------------------------------------------------
echo "Phase 1/4 — Building APK for ${SCENARIO_FILE}..."
flutter build apk \
  --debug \
  --target="${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}"
cp "${BUILD_APK}" "${APK}"
echo "Phase 1/4 — APK ready at ${APK}"

# -----------------------------------------------------------------
# Phase 2 — Install on the action-booted device. We use `-r` so
# successive runs in the same session overwrite cleanly.
# -----------------------------------------------------------------
echo "Phase 2/4 — Installing APK on ${DEVICE}..."
adb -s "${DEVICE}" install -r "${APK}"
echo "Phase 2/4 — Installed."

# -----------------------------------------------------------------
# Phase 3 — Pre-grant the runtime permissions Haven requests during
# its first MapShell mount, so Android's GrantPermissionsActivity
# dialog never pops up over the test's UI. Only dangerous-level
# permissions need (and accept) `pm grant`; install-time permissions
# from the manifest (FOREGROUND_SERVICE_*) are already active.
#
# ACCESS_BACKGROUND_LOCATION cannot be granted via `pm grant` on
# API 30+ — it requires the user to navigate through a Settings
# flow. Haven only requests it via the background-share opt-in,
# which the consolidated scenario does not exercise.
# -----------------------------------------------------------------
echo "Phase 3/4 — Granting runtime permissions on ${DEVICE}..."
for perm in \
  android.permission.ACCESS_FINE_LOCATION \
  android.permission.ACCESS_COARSE_LOCATION \
  android.permission.POST_NOTIFICATIONS
do
  if adb -s "${DEVICE}" shell pm grant com.haven.app "${perm}"; then
    echo "  granted ${perm}"
  else
    echo "  WARN: failed to grant ${perm} (continuing)"
  fi
done
echo "Phase 3/4 — Permissions ready."

# -----------------------------------------------------------------
# Phase 4 — Drive the integration test via `flutter drive`, which
# skips Gradle entirely because `--use-application-binary` points
# at the APK we just installed. The dart-defines are deliberately
# NOT passed here — they were baked into the APK during Phase 1.
# -----------------------------------------------------------------
echo "Phase 4/4 — Driving test on ${DEVICE}..."
flutter drive \
  --device-id "${DEVICE}" \
  --use-application-binary "${APK}" \
  --driver "${DRIVER_FILE}" \
  --target "${SCENARIO_FILE}"
