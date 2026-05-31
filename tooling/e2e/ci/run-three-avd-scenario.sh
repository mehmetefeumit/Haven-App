#!/usr/bin/env bash
#
# Runs the consolidated three-AVD Haven E2E scenario
# (`integration_test/e2e/e2e_combined.dart`).
#
# Alice's app runs on the action-booted `emulator-5554`; Bob's app runs
# on `emulator-5556`; Carol's app runs on `emulator-5558`. The three
# processes coordinate exclusively via events on the hermetic strfry
# relay (no side channels) — the same model production Haven uses.
#
# # Why a checked-in script
#
# The `reactivecircus/android-emulator-runner@v2` action executes
# inline `script:` blocks line-by-line under `sh -c`, breaking any
# script that relies on persisted shell state (cd, vars, background
# PIDs). Wrapping the whole flow in a single `bash <path>` invocation
# avoids that.
#
# # Architecture: serial-build, install, grant, parallel-drive
#
# Same approach as the two-AVD harness (`run-two-avd-scenario.sh`),
# extended for three roles:
#
#   1. **Phase 1 — serial build** (`flutter build apk` × 3): produce
#      one APK per role with role-specific dart-defines.
#      `HAVEN_E2E_ROLE` is read in test code (compiled into the APK
#      by `--target`), so it must be baked at build time. Builds run
#      serially against the same Gradle project, so the
#      `mergeDebugResources` intermediates directory is never
#      contended; the second and third builds are fast because
#      Gradle's incremental + build cache short-circuits everything
#      except the dart-define delta.
#
#   2. **Phase 2 — parallel install** (`adb install -r` × 3): place
#      each APK on its respective device. Done explicitly so Phase 3
#      can grant permissions before any code in the APK runs.
#
#   3. **Phase 3 — parallel permission grant** (`adb shell pm grant`
#      × 3): pre-grant Haven's dangerous-level runtime permissions
#      so Android's `GrantPermissionsActivity` dialog never pops up
#      over the test UI. Without this, Geolocator's first request
#      blocks every subsequent `tester.tap` because the dialog covers
#      the widgets the test targets.
#
#   4. **Phase 4 — parallel drive** (`flutter drive
#      --use-application-binary` × 3): each driver process picks up
#      the already-installed APK on its own device and runs the
#      integration_test via the VM service.
#      `--use-application-binary` skips Gradle entirely, so the three
#      processes never touch `haven/build/` after Phase 1 completes.
#      Coordination is exclusively via the shared strfry relay.
#
# The driver wrapper at `haven/test_driver/integration_test.dart` is
# the standard `integrationDriver()` one-liner per the integration_test
# package docs.
#
# # Memory budget
#
# Three emulators at 2 GB each plus Gradle's peak of ~2-3 GB during
# the per-role builds approaches the `ubuntu-latest` 7 GB ceiling.
# We set `-memory 1536` per emulator (4.5 GB total) so Gradle has
# enough headroom for `mergeDebugResources` without OOM-killing the
# JVM. If a future bump to GitHub-hosted larger runners is
# available, raising back to 2048 is the right call.
#
# Usage:
#   bash tooling/e2e/ci/run-three-avd-scenario.sh <scenario-file>
#
# Required env:
#   HAVEN_E2E_RELAY  WebSocket URL of the strfry relay.
#   ANDROID_HOME     Android SDK root (provided by the action).
#
# Side effects:
#   - Writes /tmp/{alice,bob,carol}-test.log    (per-role driver stdout).
#   - Writes /tmp/{alice,bob,carol}-logcat.log  (per-device logcat).
#   - Writes /tmp/{alice,bob,carol}-install.log (Phase 2 install output).
#   - Writes /tmp/{alice,bob,carol}-grant.log   (Phase 3 grant output).
#   - Writes /tmp/{bob,carol}-emulator.log      (secondary emulator stderr).
#   - Writes /tmp/{alice,bob,carol}.apk         (pre-built per-role APKs).
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
readonly CAROL_DEVICE="emulator-5558"
readonly BOB_PORT="5556"
readonly CAROL_PORT="5558"
readonly BOB_AVD_NAME="bob_avd"
readonly CAROL_AVD_NAME="carol_avd"

readonly ALICE_APK="/tmp/alice.apk"
readonly BOB_APK="/tmp/bob.apk"
readonly CAROL_APK="/tmp/carol.apk"
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
# Boot the secondary AVDs (bob_avd on 5556, carol_avd on 5558).
#
# Both are launched in the background. We wait for each in turn so a
# failure on Bob surfaces before we wait the full Carol boot budget.
# The `-memory 1536` is the per-emulator cap discussed in the header;
# adjust together with the other two if the runner profile changes.
# -----------------------------------------------------------------
start_secondary_avd() {
  local avd_name="$1"
  local port="$2"
  local log_path="$3"
  echo "Starting ${avd_name} on port ${port}..."
  "${ANDROID_HOME}/emulator/emulator" \
    -avd "${avd_name}" \
    -port "${port}" \
    -no-snapshot-save \
    -no-window \
    -gpu swiftshader_indirect \
    -noaudio \
    -no-boot-anim \
    -camera-back none \
    -memory 1536 \
    > "${log_path}" 2>&1 &
  echo $!
}

BOB_EMU_PID=$(start_secondary_avd "${BOB_AVD_NAME}" "${BOB_PORT}" /tmp/bob-emulator.log)
CAROL_EMU_PID=$(start_secondary_avd "${CAROL_AVD_NAME}" "${CAROL_PORT}" /tmp/carol-emulator.log)
readonly BOB_EMU_PID CAROL_EMU_PID

# Wait for adbd inside each AVD, then for userspace boot to complete.
# adb commands are idempotent and safe to retry.
wait_for_device_ready() {
  local device="$1"
  echo "Waiting for ${device} to come up..."
  adb -s "${device}" wait-for-device
  adb -s "${device}" shell \
    'while [[ -z $(getprop sys.boot_completed | tr -d "\r") ]]; do sleep 1; done'
  adb -s "${device}" shell input keyevent 82  # unlock screen
  echo "${device} booted."
}

wait_for_device_ready "${BOB_DEVICE}"
wait_for_device_ready "${CAROL_DEVICE}"

# -----------------------------------------------------------------
# Capture per-device logcat for the failure-artifact step.
# -----------------------------------------------------------------
adb -s "${ALICE_DEVICE}" logcat -c
adb -s "${BOB_DEVICE}"   logcat -c
adb -s "${CAROL_DEVICE}" logcat -c
adb -s "${ALICE_DEVICE}" logcat -v threadtime > /tmp/alice-logcat.log &
ALICE_LOGCAT_PID=$!
adb -s "${BOB_DEVICE}"   logcat -v threadtime > /tmp/bob-logcat.log &
BOB_LOGCAT_PID=$!
adb -s "${CAROL_DEVICE}" logcat -v threadtime > /tmp/carol-logcat.log &
CAROL_LOGCAT_PID=$!
readonly ALICE_LOGCAT_PID BOB_LOGCAT_PID CAROL_LOGCAT_PID

cleanup() {
  for pid in \
    "${ALICE_LOGCAT_PID}" \
    "${BOB_LOGCAT_PID}" \
    "${CAROL_LOGCAT_PID}" \
    "${BOB_EMU_PID}" \
    "${CAROL_EMU_PID}"
  do
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
# and third builds cheap because only the dart-define delta changed.
#
# Between builds we drop `incremental/` to free disk before the next
# Gradle pass — see run-two-avd-scenario.sh's identical block for
# the empirical "No space left on device" backstory.
# -----------------------------------------------------------------
build_role_apk() {
  local role="$1"
  local target_apk="$2"
  echo "Phase 1/4 — Building ${role}'s APK..."
  flutter build apk \
    --debug \
    --target="${SCENARIO_FILE}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_E2E_ROLE="${role}"
  cp "${BUILD_APK}" "${target_apk}"
  echo "Phase 1/4 — ${role} APK ready at ${target_apk}"
}

free_intermediates() {
  local label="$1"
  echo "Phase 1/4 — Freeing intermediates before ${label}'s build..."
  rm -rf "${HAVEN_DIR}/build/app/intermediates/incremental"
  df -h / | tail -2
}

build_role_apk "alice" "${ALICE_APK}"
free_intermediates "Bob"
build_role_apk "bob"   "${BOB_APK}"
free_intermediates "Carol"
build_role_apk "carol" "${CAROL_APK}"

# -----------------------------------------------------------------
# Phase 2 — Pre-install each APK on its device, in parallel.
#
# We install explicitly here (rather than letting `flutter drive`
# install during Phase 4) so that Phase 3 can pre-grant runtime
# permissions to the installed packages. `adb install -r` is
# idempotent, so the second install inside `flutter drive` is a
# near-no-op signature check. Permissions granted via `pm grant`
# persist across `install -r` because the package signature does
# not change.
# -----------------------------------------------------------------
echo "Phase 2/4 — Installing APKs on all three devices..."
adb -s "${ALICE_DEVICE}" install -r "${ALICE_APK}" \
  > /tmp/alice-install.log 2>&1 &
ALICE_INSTALL_PID=$!
adb -s "${BOB_DEVICE}"   install -r "${BOB_APK}" \
  > /tmp/bob-install.log 2>&1 &
BOB_INSTALL_PID=$!
adb -s "${CAROL_DEVICE}" install -r "${CAROL_APK}" \
  > /tmp/carol-install.log 2>&1 &
CAROL_INSTALL_PID=$!
readonly ALICE_INSTALL_PID BOB_INSTALL_PID CAROL_INSTALL_PID

set +e
wait "${ALICE_INSTALL_PID}"; alice_install_exit=$?
wait "${BOB_INSTALL_PID}";   bob_install_exit=$?
wait "${CAROL_INSTALL_PID}"; carol_install_exit=$?
set -e

if [[ ${alice_install_exit} -ne 0 \
    || ${bob_install_exit}   -ne 0 \
    || ${carol_install_exit} -ne 0 ]]; then
  echo "ERROR: APK install failed (alice=${alice_install_exit} " \
       "bob=${bob_install_exit} carol=${carol_install_exit})" >&2
  echo "===== alice install log ====="
  cat /tmp/alice-install.log || true
  echo "===== bob install log ====="
  cat /tmp/bob-install.log || true
  echo "===== carol install log ====="
  cat /tmp/carol-install.log || true
  exit 1
fi
echo "Phase 2/4 — APKs installed."

# -----------------------------------------------------------------
# Phase 3 — Pre-grant the runtime permissions Haven requests on its
# first MapShell mount. Without this, Android's
# GrantPermissionsActivity dialog pops up modally over the test's
# UI when Geolocator requests location access, blocking every
# subsequent `tester.tap` because the dialog covers the widgets the
# test targets. See `run-single-avd-scenario.sh` for the full
# rationale and the canonical Firebase-Test-Lab parallel.
#
# Done in parallel since `pm grant` is device-scoped. Each grant is
# best-effort: failures are logged but do not abort, because not
# every API level recognises every permission name (POST_NOTIFICATIONS
# is API 33+) and an unrecognised permission is harmless.
# -----------------------------------------------------------------
grant_permissions() {
  local device="$1"
  for perm in \
    android.permission.ACCESS_FINE_LOCATION \
    android.permission.ACCESS_COARSE_LOCATION \
    android.permission.POST_NOTIFICATIONS
  do
    if adb -s "${device}" shell pm grant com.haven.app "${perm}"; then
      echo "  ${device}: granted ${perm}"
    else
      echo "  ${device}: WARN failed to grant ${perm} (continuing)"
    fi
  done
}

echo "Phase 3/4 — Granting runtime permissions on all three devices..."
grant_permissions "${ALICE_DEVICE}" > /tmp/alice-grant.log 2>&1 &
ALICE_GRANT_PID=$!
grant_permissions "${BOB_DEVICE}"   > /tmp/bob-grant.log   2>&1 &
BOB_GRANT_PID=$!
grant_permissions "${CAROL_DEVICE}" > /tmp/carol-grant.log 2>&1 &
CAROL_GRANT_PID=$!
readonly ALICE_GRANT_PID BOB_GRANT_PID CAROL_GRANT_PID

wait "${ALICE_GRANT_PID}" || true
wait "${BOB_GRANT_PID}"   || true
wait "${CAROL_GRANT_PID}" || true

cat /tmp/alice-grant.log
cat /tmp/bob-grant.log
cat /tmp/carol-grant.log
echo "Phase 3/4 — Permissions ready."

# -----------------------------------------------------------------
# Phase 4 — Drive all three via `flutter drive --use-application-binary`
# in parallel. `flutter drive` will run `adb install -r` again, but
# that is a cheap signature check (Phase 2 already wrote the APK)
# and the runtime-permission grants from Phase 3 persist across it.
#
# Dart-defines are deliberately NOT passed to `flutter drive` — they
# are read in test code that is compiled INTO the APK by Phase 1, so
# baking them at build time is sufficient. Adding them here would be
# misleading: they'd affect the driver wrapper (which doesn't read
# them) rather than the test code (which does).
# -----------------------------------------------------------------
drive_role() {
  local device="$1"
  local apk="$2"
  local log_path="$3"
  flutter drive \
    --device-id "${device}" \
    --use-application-binary "${apk}" \
    --driver "${DRIVER_FILE}" \
    --target "${SCENARIO_FILE}" \
    > "${log_path}" 2>&1
}

echo "Phase 4/4 — Driving Alice on ${ALICE_DEVICE}..."
drive_role "${ALICE_DEVICE}" "${ALICE_APK}" /tmp/alice-test.log &
ALICE_TEST_PID=$!

echo "Phase 4/4 — Driving Bob on ${BOB_DEVICE}..."
drive_role "${BOB_DEVICE}" "${BOB_APK}" /tmp/bob-test.log &
BOB_TEST_PID=$!

echo "Phase 4/4 — Driving Carol on ${CAROL_DEVICE}..."
drive_role "${CAROL_DEVICE}" "${CAROL_APK}" /tmp/carol-test.log &
CAROL_TEST_PID=$!

readonly ALICE_TEST_PID BOB_TEST_PID CAROL_TEST_PID

# Wait for all three drivers; capture each exit code independently.
# `set +e` so a non-zero from any `wait` doesn't abort the script
# before we've collected every exit code.
set +e
wait "${ALICE_TEST_PID}"; alice_exit=$?
wait "${BOB_TEST_PID}";   bob_exit=$?
wait "${CAROL_TEST_PID}"; carol_exit=$?
set -e

echo "===== Alice (${ALICE_DEVICE}) driver output ====="
cat /tmp/alice-test.log || true
echo "===== Bob (${BOB_DEVICE}) driver output ====="
cat /tmp/bob-test.log || true
echo "===== Carol (${CAROL_DEVICE}) driver output ====="
cat /tmp/carol-test.log || true
echo "===== Exit codes: alice=${alice_exit} bob=${bob_exit} carol=${carol_exit} ====="

if [[ ${alice_exit} -ne 0 \
    || ${bob_exit}   -ne 0 \
    || ${carol_exit} -ne 0 ]]; then
  exit 1
fi
