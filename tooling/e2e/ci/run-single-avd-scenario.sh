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
# Phase 1 — obtain the test APK (use the workflow's pre-built
#                                /tmp/scenario.apk if present, else
#                                `flutter build apk` for local runs)
# Phase 2 — `adb install`           (install on the device)
# Phase 3 — `adb shell pm grant`    (pre-grant runtime permissions)
# Phase 4 — `flutter drive --use-application-binary`
#                                   (no Gradle, runs the test)
#
# In CI the APK is built in an EARLIER workflow step, before the
# emulator boots, so the heavy Rust-NDK + Gradle compile never runs
# while the emulator is resident. See docs/E2E_TROUBLESHOOTING.md.
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
# Secret-leak guard (Security Rule #6) — run after the drive, before exit.
readonly SECRET_SCAN="${script_dir}/scan-logs-for-secrets.sh"

if [[ ! -f "${HAVEN_DIR}/pubspec.yaml" ]]; then
  echo "ERROR: Haven project not found at ${HAVEN_DIR}" >&2
  exit 1
fi

if [[ ! -f "${HAVEN_DIR}/${DRIVER_FILE}" ]]; then
  echo "ERROR: ${DRIVER_FILE} missing — required by flutter drive" >&2
  exit 1
fi

if [[ ! -f "${SECRET_SCAN}" ]]; then
  echo "ERROR: secret-leak guard missing at ${SECRET_SCAN}" >&2
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
# Phase 1 — Obtain the test APK.
#
# CI builds the APK in a SEPARATE, earlier workflow step (before the
# emulator boots) so the multi-GB Rust-NDK + Gradle compile peak
# never coincides with the running emulator + strfry container —
# that concurrent memory peak previously lost the GitHub-hosted
# runner mid-step (no logs, no artifacts; see
# docs/E2E_TROUBLESHOOTING.md). When that pre-built APK is present
# at ${APK} we skip straight to install.
#
# For LOCAL runs (where nobody pre-built the APK) we fall back to
# building it here, so the script stays runnable standalone.
#
# The APK embeds BOTH the production app and the scenario's test
# code (via `--target`), so `flutter drive --use-application-binary`
# installs + drives it with no further Gradle work.
# -----------------------------------------------------------------
if [[ -f "${APK}" ]]; then
  echo "Phase 1/4 — Using pre-built APK at ${APK} (skipping build)."
else
  echo "Phase 1/4 — No pre-built APK; building for ${SCENARIO_FILE}..."
  # `--target-platform android-x64`: the AVD is x86_64, so x64 is the only
  # ABI this APK runs on. It keeps cargokit from compiling the large debug
  # Rust lib for every ABI (a multi-ABI build + NDK strip has run the CI
  # runner out of disk). Matches the workflow's pre-built APK build.
  flutter build apk \
    --debug \
    --target-platform android-x64 \
    --target="${SCENARIO_FILE}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}"
  cp "${BUILD_APK}" "${APK}"
  echo "Phase 1/4 — APK ready at ${APK}"
fi

# -----------------------------------------------------------------
# Phase 2 — Install on the action-booted device.
#
# Force-stop + uninstall any prior install FIRST, then install fresh
# (the `-r` is then a belt-and-suspenders no-op).
#
# Why not a plain `install -r`: the integration lane drives several
# targets against the SAME package (com.oblivioustech.haven) on one
# AVD. A target that mounts MapShell (e.g. app_test) starts Haven's
# background-location FOREGROUND service (flutter_foreground_task,
# START_STICKY). `install -r` does NOT clear it — Android keeps the
# sticky service and reconnects it to the NEXT target's Flutter engine,
# which keeps that app alive and busy and wedges `flutter drive`'s final
# `request_data` handshake. Observed as a ~25-min hang in keyring_test
# (a pure-FFI test that never touches location) until the job's 45-min
# cap, cancelling the whole lane. Uninstalling removes the package and
# every component — services included — so each target starts clean.
# Harmless for the single-target e2e_combined run (guarantees a fresh
# install). The leading force-stop/uninstall are best-effort: a missing
# package makes them exit non-zero, which `|| true` swallows.
# -----------------------------------------------------------------
echo "Phase 2/4 — Clearing any prior install on ${DEVICE}..."
adb -s "${DEVICE}" shell am force-stop com.oblivioustech.haven || true
adb -s "${DEVICE}" uninstall com.oblivioustech.haven >/dev/null 2>&1 || true
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
  if adb -s "${DEVICE}" shell pm grant com.oblivioustech.haven "${perm}"; then
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
#
# The Dart test-reporter output (which phase failed, the EXCEPTION
# block, the stack) is captured into /tmp/flutter-drive.log via a
# plain REDIRECT — never `flutter drive ... | tee file`. See the
# comment on the drive invocation below for why a pipe here is a
# latent job-killer; the short version is that a pipe makes the
# shell wait for `tee` to see EOF, which a `timeout`-killed drive's
# orphaned `adb` children can defer indefinitely. The file is still
# written in real time and uploaded as a failure artifact; we `cat`
# it afterwards so the step console still shows it (the
# `reactivecircus/android-emulator-runner` action buffers step
# stdout until the script exits anyway, so a live `tee` never bought
# real-time console visibility to begin with).
# -----------------------------------------------------------------
# Per-drive timeout. `flutter drive` can hang AFTER the tests pass if the
# app never goes idle — e.g. a lingering foreground service or periodic
# timer blocking the final `request_data` result handshake. Unbounded, one
# hung drive consumes the entire job (observed: the 45-min cap fires and the
# whole lane is cancelled, masking every other target). `timeout` converts
# that into a fast, clearly-attributed per-target failure (rc 124) so the
# remaining targets still run and the log names the culprit. The generous
# default protects the long e2e_combined flow; the multi-target integration
# lane overrides it tighter via HAVEN_DRIVE_TIMEOUT (run-integration-tests.sh).
readonly DRIVE_TIMEOUT="${HAVEN_DRIVE_TIMEOUT:-20m}"

echo "Phase 4/4 — Driving test on ${DEVICE} (timeout ${DRIVE_TIMEOUT})..."
# Capture the drive's exit code without letting `set -e` abort before the
# secret scan runs. `timeout --kill-after` escalates to SIGKILL if flutter
# drive ignores the initial SIGTERM.
#
# Output goes to the log file via a plain REDIRECT, NOT `... | tee file`.
# A pipe makes the shell wait for the WHOLE pipeline — i.e. until `tee` sees
# EOF on stdin, which only happens once EVERY process holding the pipe's
# write-end has closed it. When `timeout` kills a hung `flutter drive`, the
# drive's orphaned `adb` children re-parent to init and keep that write-end
# open, so `tee` blocks forever and the `timeout` we rely on is silently
# defeated: the script hangs PAST its own bound until the 60-min JOB timeout
# SIGKILLs everything — before the `if: failure()` diagnostic + artifact
# steps can run, yielding a 1-hour "did not complete" with zero logs
# (observed: run 28056995601, e2e_android, ~47-min step hang). A `>` redirect
# has no reader to block: `timeout` waits only on its direct child, so the
# instant the drive is killed the script proceeds, the rc is captured, and
# the clean failure lets diagnostics upload. `cat` mirrors the log to the
# step console afterwards (the action buffers stdout until exit regardless).
drive_rc=0
# `--no-pub`: skip the implicit `flutter pub get` that `flutter drive`
# runs first. In CI the deps are already resolved (the workflow's "Get
# Flutter dependencies" step AND the APK build both ran `pub get`), and
# the network-egress guard rejects outbound :443 — so the implicit pub
# get's pub.dev advisory fetch
# (https://pub.dev/api/packages/archive/advisories) fails with "Network
# is unreachable" and aborts the entire drive BEFORE the app launches
# (root cause of run 28069207592: a clean ~2.5-min failure, no app, no
# relay traffic). Skipping it keeps the guarded run hermetic and faster;
# .dart_tool/package_config.json is already present so the drive needs no
# resolution. The local-run build branch above still resolves deps
# (no guard locally), so standalone runs are unaffected.
timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
  --no-pub \
  --device-id "${DEVICE}" \
  --use-application-binary "${APK}" \
  --driver "${DRIVER_FILE}" \
  --target "${SCENARIO_FILE}" > /tmp/flutter-drive.log 2>&1 || drive_rc=$?
cat /tmp/flutter-drive.log || true

if (( drive_rc == 124 || drive_rc == 137 )); then
  echo "ERROR: flutter drive for ${SCENARIO_FILE} exceeded ${DRIVE_TIMEOUT}" \
       "and was killed (rc=${drive_rc}); treating as a target failure." >&2
fi

# -----------------------------------------------------------------
# Secret-leak guard (CLAUDE.md Security Rule #6). Scan the captured
# logcat + drive logs for key material (e.g. keyring-core dumping the
# SQLCipher DB-key bytes at DEBUG). This runs REGARDLESS of the test's
# own pass/fail, so a leak can't ride along on a green run — a hit fails
# the scenario even when the test itself passed.
# -----------------------------------------------------------------
echo "Scanning E2E logs for secret material..."
scan_rc=0
bash "${SECRET_SCAN}" /tmp/adb-logcat.log /tmp/flutter-drive.log || scan_rc=$?
if (( scan_rc != 0 )); then
  echo "ERROR: secret-leak guard tripped — see LEAK line(s) above." >&2
  exit 1
fi

exit "${drive_rc}"
