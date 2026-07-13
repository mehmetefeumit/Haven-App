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

# -----------------------------------------------------------------
# is_connect_flake <drive-log> — exit 0 (retryable) iff the drive died in
# the flutter_driver CONNECT phase with NO on-device test having run; exit 1
# otherwise. Pure text inspection: takes no device and is safe to unit-test.
#
# flutter_driver's `VMServiceFlutterDriver.connect()` prints
# "Connected to Flutter application." as its LAST action on success —
# strictly BEFORE `integrationDriver()` calls `driver.requestData()`, the
# call that actually runs/awaits the on-device test body. So the ABSENCE of
# that line proves no assertion ever executed, and anchoring on it (rather
# than a specific stack-frame string) is robust across Flutter SDK versions
# and generalizes to EVERY pre-connect "Collected"-sentinel variant (isolate
# resume / GetVM / GetIsolate / GetHealth). A DriverError raised AFTER connect
# (mid-test) is therefore NEVER treated as a flake — the first check short-
# circuits — so a real assertion/RPC failure always surfaces and test quality
# is never lowered.
#
# Observed instance (CI run 29218745757, smoke_test on the cold first target):
#   "DriverError: Failed to fulfill GetHealth ... [Sentinel kind: Collected]"
#   from VMServiceFlutterDriver.connect — the app isolate was GC'd while
#   checkHealth's single (non-retried) RPC was in flight, because the Android
#   activity/engine was recreated mid-handshake on cold boot. This is a known
#   flutter_driver connect race (flutter/flutter#68334, #95063), not an app
#   bug: `connect()` health-checks exactly once with no retry surface.
#
# Caveat: a RARE intermittent app crash DURING startup (pre-connect) is
# indistinguishable from this race and would also be retried. A DETERMINISTIC
# startup crash still surfaces — every attempt fails, the true rc is returned —
# so this only ever masks a genuinely transient pre-connect fault, the accepted
# tradeoff inherent to any connect-phase retry.
is_connect_flake() {
  local log="$1"
  [[ -f "${log}" ]] || return 1

  # Success marker present -> the driver connected; any later failure is a
  # genuine test/RPC failure, never a connect flake.
  if grep -qF 'Connected to Flutter application.' "${log}"; then
    return 1
  fi
  # Any flutter_test compact-reporter progress ("MM:SS +N...") or summary line
  # means the app was actually driving tests -> not a connect flake.
  if grep -qE 'Some tests failed\.|All tests (passed!|skipped\.)|^[0-9]{2}:[0-9]{2} \+[0-9]+' "${log}"; then
    return 1
  fi
  # Require POSITIVE evidence this was a connect ATTEMPT that threw (not a
  # build / install / pub-get failure that never reached `flutter drive`, and
  # not an empty/truncated log).
  if ! grep -qF 'VMServiceFlutterDriver: Connecting to Flutter application' "${log}"; then
    return 1
  fi
  if ! grep -qE 'DriverError|Unhandled exception' "${log}"; then
    return 1
  fi
  return 0
}

# --self-test — validate is_connect_flake against synthetic drive logs WITHOUT
# a device/emulator (mirrors scan-logs-for-secrets.sh --self-test). CI gates
# the predicate through this in a fast, hermetic job so it can never silently
# rot. The critical fixture (#3) proves a real post-connect failure is NOT
# retried, i.e. the retry can never mask a bug.
run_self_test() {
  local tmp fail=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  # (1) TRUE POSITIVE — the observed connect-phase flake: driver connected to
  #     an isolate, health-checked it, and the isolate was Collected. No test
  #     ran. MUST be flagged retryable.
  printf '%s\n' \
    'VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:35467/xyz=/' \
    'VMServiceFlutterDriver: Isolate found with number: 4631700024078619' \
    'VMServiceFlutterDriver: Isolate is paused at start.' \
    'VMServiceFlutterDriver: Attempting to resume isolate' \
    'Unhandled exception:' \
    'DriverError: Failed to fulfill GetHealth due to remote error' \
    'Original error: [Sentinel kind: Collected, valueAsString: <collected>] from ext.flutter.driver()' \
    '#6      VMServiceFlutterDriver.connect (package:flutter_driver/src/driver/vmservice_driver.dart:248:40)' \
    > "${tmp}/flake.log"
  if ! is_connect_flake "${tmp}/flake.log"; then
    echo "SELF-TEST FAIL: a genuine connect-phase flake was NOT detected" >&2
    fail=1
  fi

  # (2) TRUE NEGATIVE — a clean full pass. The driver connected and every test
  #     passed. MUST NOT be retried.
  printf '%s\n' \
    'VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:40001/abc=/' \
    'VMServiceFlutterDriver: Connected to Flutter application.' \
    '00:03 +1: Phase 0 E2E infrastructure smoke test' \
    '00:07 +5: All tests passed!' \
    > "${tmp}/pass.log"
  if is_connect_flake "${tmp}/pass.log"; then
    echo "SELF-TEST FAIL: a clean passing run was misclassified as a flake" >&2
    fail=1
  fi

  # (3) TRUE NEGATIVE (the critical one) — a GENUINE test failure AFTER a
  #     successful connect. A later RPC can raise the same DriverError shape;
  #     retrying it would MASK a real bug, so it MUST NOT be flagged.
  printf '%s\n' \
    'VMServiceFlutterDriver: Connecting to Flutter application at http://127.0.0.1:40002/def=/' \
    'VMServiceFlutterDriver: Connected to Flutter application.' \
    '00:04 +0 -1: some scenario [E]' \
    'Expected: true  Actual: <false>' \
    'DriverError: Failed to fulfill WaitFor due to remote error' \
    'Some tests failed.' \
    > "${tmp}/realfail.log"
  if is_connect_flake "${tmp}/realfail.log"; then
    echo "SELF-TEST FAIL: a real post-connect test failure was misclassified as a flake (would mask a bug)" >&2
    fail=1
  fi

  # (4) TRUE NEGATIVE — a failure that never reached the driver connect attempt
  #     (no "Connecting to Flutter application", no DriverError). MUST NOT be
  #     retried as a connect flake.
  printf '%s\n' \
    'Phase 4/4 — Driving test on emulator-5554 ...' \
    'Gradle task assembleDebug failed with exit code 1' \
    > "${tmp}/build-fail.log"
  if is_connect_flake "${tmp}/build-fail.log"; then
    echo "SELF-TEST FAIL: a non-connect failure was misclassified as a flake" >&2
    fail=1
  fi

  if (( fail )); then
    echo "run-single-avd-scenario: SELF-TEST FAILED" >&2
    return 1
  fi
  echo "run-single-avd-scenario: self-test passed (connect flake caught; clean pass, real post-connect failure, and non-connect failure all correctly NOT retried)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scenario-file>  |  $0 --self-test" >&2
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
# Bounded retry for flutter_driver CONNECT-phase flakes (see is_connect_flake).
# The cold-boot activity/engine recreate that GCs the app isolate mid-connect
# is transient and app-state-independent, so a force-stop + relaunch of the
# SAME installed APK reliably clears it (a fresh reinstall is strictly colder,
# i.e. more exposed to the race). 3 total attempts mirrors flutter_tools' own
# driver-launch retry (flutter/flutter#68334) and issue #95063's N=2-3. ONLY a
# pure connect flake is retried — a genuine test failure fails the predicate,
# and a hang (rc 124/137) is excluded — so this can never mask a bug, and the
# worst case adds retries that each fail in seconds (a Collected isolate fails
# fast), never a full DRIVE_TIMEOUT.
readonly DRIVE_MAX_ATTEMPTS="${HAVEN_DRIVE_MAX_ATTEMPTS:-3}"
readonly DRIVE_RETRY_SETTLE_SECS="${HAVEN_DRIVE_RETRY_SETTLE_SECS:-5}"
# Validate the attempt count as a positive integer (mirrors run-flake-stress.sh).
# A non-positive/garbage value would make the drive loop never enter and the
# script `exit 0` having run NOTHING — a silent false-green that disables the
# test. Fail loudly instead.
if ! [[ "${DRIVE_MAX_ATTEMPTS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_DRIVE_MAX_ATTEMPTS must be a positive integer, got" \
       "'${DRIVE_MAX_ATTEMPTS}'" >&2
  exit 2
fi

# Connect-phase watchdog. A separate, SHORTER deadline than DRIVE_TIMEOUT for
# the driver to reach "Connected to Flutter application." (its last connect-
# success action, strictly before any test runs). If it is not reached in time,
# the app isolate stalled BEFORE running any test code — the flag-on Android
# cold-emulator startup-capacity stall (heavier build → slower JIT warm-up →
# the isolate's resume RPC never gets serviced), a documented, non-deterministic
# infra failure (docs/E2E_TROUBLESHOOTING.md "Failure mode 3"), NOT a product
# bug (the identical Rust runs fine on iOS and flag-off Android). Rather than
# burn the full DRIVE_TIMEOUT and then fail unretried, the watchdog kills the
# stalled drive at this deadline so it is retried FAST with a fresh launch. A
# normal cold connect completes in << 2 min, so 5 min is generous headroom that
# never trips a healthy (if slow) launch, while sitting well under DRIVE_TIMEOUT
# so a genuine post-connect test hang is unaffected (it only fires pre-connect).
# It is ALSO bounded by the lane's outer job `timeout` (35 min for live_sync,
# which also wraps setup-network-guard + install/grant + the post-drive secret
# scan): the worst case is `(DRIVE_MAX_ATTEMPTS-1) × CONNECT_WATCHDOG +
# DRIVE_TIMEOUT + (guard+install+grant+scan overhead)`, i.e.
# `2×5 + 20 + ~3 = 33 min < 35 min`, so even a run that stalls then recovers on
# a full retry stays clean inside the envelope rather than tripping a blind
# outer SIGKILL that would lose the failure diagnostics. (Hangs are rc 124/137,
# excluded from retry, so there is at most ONE full-DRIVE_TIMEOUT attempt.)
readonly CONNECT_WATCHDOG_SECS="${HAVEN_DRIVE_CONNECT_WATCHDOG_SECS:-300}"
readonly WATCHDOG_POLL_SECS="${HAVEN_DRIVE_WATCHDOG_POLL_SECS:-5}"
if ! [[ "${CONNECT_WATCHDOG_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_DRIVE_CONNECT_WATCHDOG_SECS must be a positive integer," \
       "got '${CONNECT_WATCHDOG_SECS}'" >&2
  exit 2
fi

# The literal the flutter_driver host prints as its LAST successful-connect
# action, strictly before any on-device test runs. Both the watchdog (below)
# and is_connect_flake key on its presence/absence.
readonly CONNECT_MARKER='Connected to Flutter application.'

# spawn_flutter_drive <log> — backgrounds one `flutter drive` under DRIVE_TIMEOUT,
# redirecting its output to <log>. Factored out (a) so the whole invocation lives
# in one place, and (b) as a seam: a future hermetic --self-test can override it
# with a synthetic drive (a `sleep` for a stall, an echo of CONNECT_MARKER for a
# connect) to exercise drive_with_connect_watchdog with no device. `$!` set by the
# `&` here remains readable by the caller after this function returns (bash keeps
# the last-background PID shell-global), so the caller reads `drive_pid=$!`. The
# watchdog control flow is currently validated by an external stubbed-drive
# simulation (pass / real-failure / stall / stall-then-recover).
spawn_flutter_drive() {
  timeout --kill-after=30s "${DRIVE_TIMEOUT}" flutter drive \
    --no-pub \
    --device-id "${DEVICE}" \
    --use-application-binary "${APK}" \
    --driver "${DRIVER_FILE}" \
    --target "${SCENARIO_FILE}" > "$1" 2>&1 &
}

# drive_with_connect_watchdog <attempt-log> — runs one `flutter drive` under
# BOTH the overall DRIVE_TIMEOUT and a shorter connect-phase watchdog. Sets two
# globals for the caller: `drive_rc` (the drive's exit code) and
# `preconnect_stall` (1 iff the watchdog killed it for never connecting).
#
# The drive runs backgrounded so a concurrent watchdog can monitor its live log
# (a plain `>` redirect writes in real time) for CONNECT_MARKER and kill it if
# the connect never lands. This never masks a real failure: the watchdog only
# fires when CONNECT_MARKER is ABSENT, which is provably before any test code
# ran (see is_connect_flake's rationale).
drive_with_connect_watchdog() {
  local log="$1"
  local stall_flag="${log}.stall"
  rm -f "${stall_flag}"
  drive_rc=0
  preconnect_stall=0

  spawn_flutter_drive "${log}"
  local drive_pid=$!

  (
    local waited=0
    while (( waited < CONNECT_WATCHDOG_SECS )); do
      sleep "${WATCHDOG_POLL_SECS}"
      waited=$(( waited + WATCHDOG_POLL_SECS ))
      # Drive already exited (connected+ran, or failed fast) — stand down.
      kill -0 "${drive_pid}" 2>/dev/null || exit 0
      # Connected — the test is running; let DRIVE_TIMEOUT govern from here.
      if grep -qF "${CONNECT_MARKER}" "${log}" 2>/dev/null; then
        exit 0
      fi
    done
    # Deadline hit. Stand down if the drive already exited, OR if it connected
    # in the sub-poll window between the final in-loop grep and now (re-check the
    # marker so a just-connected run is never mislabeled a stall — the boundary
    # false-positive guard).
    kill -0 "${drive_pid}" 2>/dev/null || exit 0
    if grep -qF "${CONNECT_MARKER}" "${log}" 2>/dev/null; then
      exit 0
    fi
    # Still not connected → a pre-connect stall. Mark it and kill the drive so
    # the loop retries fast instead of waiting out DRIVE_TIMEOUT.
    : > "${stall_flag}"
    echo "WATCHDOG: 'Connected to Flutter application.' not reached within" \
         "${CONNECT_WATCHDOG_SECS}s — killing a pre-connect stall." >> "${log}"
    kill -TERM "${drive_pid}" 2>/dev/null || true
    sleep 5
    kill -KILL "${drive_pid}" 2>/dev/null || true
  ) &
  local watchdog_pid=$!

  wait "${drive_pid}" 2>/dev/null || drive_rc=$?
  # Stop the watchdog if it is still waiting (drive finished on its own); a
  # no-op if it already stood down or fired.
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
  if [[ -f "${stall_flag}" ]]; then
    preconnect_stall=1
  fi
  rm -f "${stall_flag}"
}

echo "Phase 4/4 — Driving test on ${DEVICE} (timeout ${DRIVE_TIMEOUT}," \
     "connect-watchdog ${CONNECT_WATCHDOG_SECS}s, up to ${DRIVE_MAX_ATTEMPTS} attempt(s))..."
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
#
# The drive is wrapped in a bounded retry that re-runs ONLY a pure
# flutter_driver CONNECT-phase flake (is_connect_flake): the app isolate
# GC'd during the single non-retried checkHealth on cold boot, before any
# test ran. A genuine assertion failure fails the predicate and a hang (rc
# 124/137) is excluded, so neither is ever retried — real bugs and real
# hangs still fail fast with their true rc. Classification is per-attempt
# (on ${attempt_log}, not the accumulated log) so a real failure on a later
# attempt is never masked by an earlier attempt's connect flake.
drive_rc=0
attempt=1
: > /tmp/flutter-drive.log
while (( attempt <= DRIVE_MAX_ATTEMPTS )); do
  attempt_log="/tmp/flutter-drive.attempt${attempt}.log"
  # Sets drive_rc + preconnect_stall (the watchdog kills a never-connecting
  # drive early so it fails fast instead of burning the full DRIVE_TIMEOUT).
  drive_with_connect_watchdog "${attempt_log}"

  # Accumulate every attempt's output (with a header) into the canonical
  # drive log that the secret scan + failure-artifact upload consume, so a
  # retry never discards the earlier attempt's evidence.
  {
    echo "===== flutter drive attempt ${attempt}/${DRIVE_MAX_ATTEMPTS}" \
         "(rc=${drive_rc}, preconnect_stall=${preconnect_stall}) ====="
    cat "${attempt_log}"
  } >> /tmp/flutter-drive.log

  if (( drive_rc == 0 )); then
    rm -f "${attempt_log}"
    break
  fi

  # Retry a CONNECT-PHASE failure — either (a) a pre-connect STALL the watchdog
  # killed for never reaching CONNECT_MARKER (cold-emulator startup-capacity
  # stall), or (b) a fast connect flake (is_connect_flake: a DriverError at
  # connect, e.g. a Collected isolate). BOTH are provably pre-test (no
  # CONNECT_MARKER, no reporter progress), so retrying with a fresh launch can
  # never mask a real regression. A genuine post-connect test failure/hang is
  # neither, so it surfaces with its true rc.
  if (( attempt < DRIVE_MAX_ATTEMPTS )) \
     && { (( preconnect_stall == 1 )) \
          || { (( drive_rc != 124 && drive_rc != 137 )) \
               && is_connect_flake "${attempt_log}"; }; }; then
    if (( preconnect_stall == 1 )); then
      echo "WARN: flutter drive for ${SCENARIO_FILE} hit a PRE-CONNECT STALL" \
           "(attempt ${attempt}/${DRIVE_MAX_ATTEMPTS}, rc=${drive_rc}) — the" \
           "app isolate never reached 'Connected to Flutter application.'" \
           "within ${CONNECT_WATCHDOG_SECS}s and no on-device test ran (likely" \
           "a cold-emulator startup-capacity stall); force-stopping and" \
           "retrying with a fresh launch." >&2
    else
      echo "WARN: flutter drive for ${SCENARIO_FILE} hit a flutter_driver" \
           "CONNECT-phase flake (attempt ${attempt}/${DRIVE_MAX_ATTEMPTS}," \
           "rc=${drive_rc}) — the app never reached 'Connected to Flutter" \
           "application.' and no on-device test ran; force-stopping and" \
           "retrying the same installed APK." >&2
    fi
    rm -f "${attempt_log}"
    adb -s "${DEVICE}" shell am force-stop com.oblivioustech.haven || true
    sleep "${DRIVE_RETRY_SETTLE_SECS}"
    attempt=$(( attempt + 1 ))
    continue
  fi

  rm -f "${attempt_log}"
  break
done
cat /tmp/flutter-drive.log || true

if (( preconnect_stall == 1 )); then
  echo "ERROR: flutter drive for ${SCENARIO_FILE} never connected within" \
       "${CONNECT_WATCHDOG_SECS}s on the final attempt (pre-connect stall," \
       "rc=${drive_rc}); treating as a target failure." >&2
elif (( drive_rc == 124 || drive_rc == 137 )); then
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
