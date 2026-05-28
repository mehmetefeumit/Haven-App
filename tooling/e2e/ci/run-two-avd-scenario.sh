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
# # Architecture: serial-build, install, grant, parallel-drive
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
# separates build (Gradle) from drive (test execution), with a
# permission-grant step inserted between install and drive so the
# production app's runtime-permission dialogs don't block the test's
# UI interactions:
#
#   1. **Phase 1 — serial build** (`flutter build apk` x 2): produce
#      one APK per role with role-specific dart-defines.
#      `HAVEN_E2E_ROLE` is read in test code (compiled into the APK
#      by `--target`), so it must be baked at build time. Builds run
#      serially against the same Gradle project, so the intermediates
#      directory is never contended; the second build is fast because
#      Gradle's incremental + build cache short-circuits everything
#      except the dart-define delta.
#
#   2. **Phase 2 — parallel install** (`adb install -r` x 2): place
#      each APK on its respective device. Done explicitly so Phase 3
#      can grant permissions before any code in the APK runs.
#
#   3. **Phase 3 — parallel permission grant** (`adb shell pm grant`
#      x 2): pre-grant Haven's dangerous-level runtime permissions
#      so Android's GrantPermissionsActivity dialog never pops up
#      over the test UI. Without this, Geolocator's first request
#      blocks Alice's drag-and-tap flow behind a system dialog.
#
#   4. **Phase 4 — parallel drive** (`flutter drive
#      --use-application-binary` x 2): each driver process picks up
#      the already-installed APK on its own device and runs the
#      integration_test test via the VM service.
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
#   - Writes /tmp/{alice,bob}-test.log    (per-role driver stdout).
#   - Writes /tmp/{alice,bob}-logcat.log  (per-device logcat).
#   - Writes /tmp/{alice,bob}-install.log (Phase 2 adb install output).
#   - Writes /tmp/{alice,bob}-grant.log   (Phase 3 pm grant output).
#   - Writes /tmp/bob-emulator.log        (bob_avd emulator stderr).
#   - Writes /tmp/{alice,bob}.apk         (pre-built per-role APKs).
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
echo "Phase 1/4 — Building Alice's APK..."
flutter build apk \
  --debug \
  --target="${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=alice
cp "${BUILD_APK}" "${ALICE_APK}"
echo "Phase 1/4 — Alice APK ready at ${ALICE_APK}"

# Free disk between the two APK builds. Each `flutter build apk`
# writes to `haven/build/app/intermediates/...` and the Gradle
# transforms cache (`~/.gradle/caches/transforms-*`) keeps both
# runs' extracted Flutter JNIs side-by-side. On GitHub-hosted
# runners (~14 GB free after the OS) the cumulative footprint of
# Alice's build + Bob's build hits the disk ceiling during Bob's
# `mergeDebugNativeLibs`, surfacing as `No space left on device`.
# We free what we safely can without invalidating the Gradle build
# cache that makes Bob's incremental build cheap:
#   - `haven/build/app/intermediates/incremental/`: Gradle's per-
#     project incremental snapshot, regenerated by every build.
#     Safe to drop. The next build pays an incremental-analysis
#     cost (~30 s) but never a from-scratch cost.
#   - `df -h /`: surface the remaining disk so a future "still
#     full" failure is visible immediately in the CI log.
echo "Phase 1/4 — Freeing intermediates before Bob's build..."
rm -rf "${HAVEN_DIR}/build/app/intermediates/incremental"
df -h / | tail -2

echo "Phase 1/4 — Building Bob's APK..."
flutter build apk \
  --debug \
  --target="${SCENARIO_FILE}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  --dart-define=HAVEN_E2E_ROLE=bob
cp "${BUILD_APK}" "${BOB_APK}"
echo "Phase 1/4 — Bob APK ready at ${BOB_APK}"

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
echo "Phase 2/4 — Installing APKs on both devices..."
adb -s "${ALICE_DEVICE}" install -r "${ALICE_APK}" \
  > /tmp/alice-install.log 2>&1 &
readonly ALICE_INSTALL_PID=$!
adb -s "${BOB_DEVICE}"   install -r "${BOB_APK}" \
  > /tmp/bob-install.log 2>&1 &
readonly BOB_INSTALL_PID=$!

set +e
wait "${ALICE_INSTALL_PID}"; alice_install_exit=$?
wait "${BOB_INSTALL_PID}";   bob_install_exit=$?
set -e

if [[ ${alice_install_exit} -ne 0 || ${bob_install_exit} -ne 0 ]]; then
  echo "ERROR: APK install failed (alice=${alice_install_exit} bob=${bob_install_exit})" >&2
  echo "===== alice install log ====="
  cat /tmp/alice-install.log || true
  echo "===== bob install log ====="
  cat /tmp/bob-install.log || true
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

echo "Phase 3/4 — Granting runtime permissions on both devices..."
grant_permissions "${ALICE_DEVICE}" > /tmp/alice-grant.log 2>&1 &
readonly ALICE_GRANT_PID=$!
grant_permissions "${BOB_DEVICE}"   > /tmp/bob-grant.log   2>&1 &
readonly BOB_GRANT_PID=$!

wait "${ALICE_GRANT_PID}" || true
wait "${BOB_GRANT_PID}"   || true

cat /tmp/alice-grant.log
cat /tmp/bob-grant.log
echo "Phase 3/4 — Permissions ready."

# -----------------------------------------------------------------
# Phase 4 — Drive both via `flutter drive --use-application-binary`
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
echo "Phase 4/4 — Driving Alice on ${ALICE_DEVICE}..."
flutter drive \
  --device-id "${ALICE_DEVICE}" \
  --use-application-binary "${ALICE_APK}" \
  --driver "${DRIVER_FILE}" \
  --target "${SCENARIO_FILE}" \
  > /tmp/alice-test.log 2>&1 &
readonly ALICE_TEST_PID=$!

echo "Phase 4/4 — Driving Bob on ${BOB_DEVICE}..."
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
