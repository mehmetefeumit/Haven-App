#!/usr/bin/env bash
#
# iOS-simulator E2E scenario runner (Tier 1).
#
# Mirrors run-single-avd-scenario.sh, but for an iOS simulator. A real
# iOS-Alice UI runs the consolidated `e2e_combined.dart` flow on the booted
# simulator while Bob/Carol/Dave participate as in-process `SyntheticUser`
# FFI peers. All actors coordinate through a host-native Nostr relay at
# `ws://localhost:7777` — the macOS runner has no Linux Docker daemon, so the
# Android lane's `strfry` container cannot run there (see
# tooling/e2e/local-relay/).
#
# Differences from the Android lane:
#   - No `adb install` / `pm grant`: `flutter test -d <udid>` builds, installs,
#     runs, and reports in one step.
#   - No native location-permission grant: the scenario overrides
#     `locationServiceProvider` with `FakeLocationService` (reports permission
#     `always`), so CLLocationManager is never touched.
#   - The simulator reaches the host relay at `localhost` (it shares the host
#     network namespace), NOT the Android `10.0.2.2` alias.
#
# `flutter test` builds in DEBUG, so the `#[cfg(debug_assertions)]` Rust test
# hooks (in-memory keyring, ws:// loopback allow-list, relay override) are
# active — exactly as the Android lane relies on.
#
# Usage:
#   run-ios-sim-scenario.sh <scenario-file> <simulator-udid>
#
# Environment:
#   HAVEN_E2E_RELAY  WebSocket URL of the host relay (default
#                    ws://localhost:7777). Compiled into the test build via
#                    --dart-define so it must match the running relay.
#   HAVEN_LIVE_SYNC  'true' or 'false'. MANDATORY — set per STEP by the caller
#                    (S1). There is deliberately no default; see below.
#   HAVEN_E2E_BLOSSOM_URL  Base URL of the host-native Blossom server, used
#                    ONLY by the public-profile lane (e2e-profile.yml). When
#                    set, it is threaded into the build as a --dart-define;
#                    when UNSET (every other lane), no such define is added, so
#                    those lanes' compiled builds stay byte-identical
#                    (backward-compatible).
#   HAVEN_E2E_PROFILE_RELAY   ws:// URL of the FIRST profile-plane relay, and
#   HAVEN_E2E_PROFILE_RELAYS  the comma-separated URL list of the whole
#                    profile-plane pool (tooling/e2e/ci/start-profile-relays.sh).
#                    Also public-profile-lane-only: kind-0 traffic must ride
#                    relays DISJOINT from the circle relay in HAVEN_E2E_RELAY.
#                    Same opt-in shape as HAVEN_E2E_BLOSSOM_URL — forwarded only
#                    when set, so no other lane's build changes.
#
# Retry discipline (CI_HARDENING_BACKLOG.md A6):
#   Both iOS callers wrap this script in `nick-fields/retry@v3` with no
#   `retry_on` filter, so the action retries EVERY non-zero exit — a genuine
#   assertion failure exactly like a simulator that never launched. Measured
#   across 156 attempts, 19 genuine test failures were retried and the only
#   real infrastructure flake was a post-build, pre-first-test launch/attach
#   stall. This script now (a) runs a first-test watchdog that kills such a
#   stall on a deadline SHORTER than the attempt timeout, so it is attributed
#   instead of being an anonymous "Timeout of 1800000ms hit", and (b) records a
#   verdict that makes the NEXT attempt refuse to run unless that one signature
#   was proven. See tooling/e2e/ci/ios-flake-lib.sh.
#
# Usage (self-test):
#   run-ios-sim-scenario.sh --self-test   # hermetic; no simulator, no Xcode
#
# Side effects:
#   - Writes /tmp/flutter-ios-test.log (uploaded as a CI failure artifact).
#   - Writes /tmp/haven-ios-retry-verdict-<scenario-slug> (cross-attempt state).
#
# Exit status: the `flutter test` exit code (0 = scenario passed).

set -euo pipefail

# Sourced BEFORE the --self-test dispatch below so the self-test exercises a
# runner wired exactly like the real one (the same discipline
# run-single-avd-scenario.sh applies to drive-log-lib.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# shellcheck source=tooling/e2e/ci/ios-flake-lib.sh
source "${SCRIPT_DIR}/ios-flake-lib.sh"

# How long after the Xcode build finishes the on-device suite has to say
# ANYTHING before the watchdog calls it a launch/attach stall. Measured over 164
# real attempts, build-done → first reporter line is 32s median, 53s p90, 94s
# max, so 300s is >3x the worst observed and cannot trip a healthy (if slow)
# launch. It must also stay well UNDER the caller's per-attempt
# `timeout_minutes` (20-45 min), because a stall that the OUTER timeout kills
# first is never classified and therefore — by design — never retried.
readonly FIRST_TEST_WATCHDOG_SECS="${HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS:-300}"
readonly WATCHDOG_POLL_SECS="${HAVEN_IOS_WATCHDOG_POLL_SECS:-5}"
# Validate as positive integers (mirrors run-single-avd-scenario.sh). A garbage
# value would make the watchdog loop misbehave rather than fail loudly.
if ! [[ "${FIRST_TEST_WATCHDOG_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS must be a positive integer," \
       "got '${FIRST_TEST_WATCHDOG_SECS}'" >&2
  exit 2
fi
if ! [[ "${WATCHDOG_POLL_SECS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: HAVEN_IOS_WATCHDOG_POLL_SECS must be a positive integer, got" \
       "'${WATCHDOG_POLL_SECS}'" >&2
  exit 2
fi

# spawn_ios_test <log> — backgrounds ONE `flutter test`, redirecting its output
# to <log>. Factored out (a) so the whole invocation lives in one place and
# (b) as the seam the --self-test at the foot of this file overrides with a
# synthetic "build then stall" / "build then run" / "fail fast" process, which is
# how the watchdog's control flow is proven without a simulator.
#
# `$!` set by the `&` here stays readable by the caller after the function
# returns (bash keeps the last-background PID shell-global).
#
# Output goes through a plain REDIRECT, not `| tee`: when the watchdog kills a
# stalled `flutter test`, its orphaned children keep the pipe's write end open,
# so `tee` would block forever on EOF and defeat the very bound we rely on —
# the failure run-single-avd-scenario.sh documents at length (run 28056995601,
# a ~47-min step hang). A follower streams the log to the console instead.
spawn_ios_test() {
  # The `${EXTRA_DART_DEFINES[@]+"..."}` form is the nounset-safe idiom for
  # expanding a possibly-empty array under `set -u` on bash 3.2 (the macOS
  # runner default): it expands to the quoted elements when set and to nothing
  # when the array is empty, so a lane that did not set HAVEN_E2E_BLOSSOM_URL
  # adds no arg.
  flutter test "${SCENARIO_FILE}" \
    -d "${SIM_UDID}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_LIVE_SYNC="${LIVE_SYNC}" \
    --dart-define=HAVEN_E2E_NO_BACKGROUND="${E2E_NO_BACKGROUND}" \
    ${EXTRA_DART_DEFINES[@]+"${EXTRA_DART_DEFINES[@]}"} \
    > "$1" 2>&1 &
}

# run_ios_test_with_watchdog <log> — runs one `flutter test` under a first-test
# watchdog. Sets `ios_test_rc` for the caller.
#
# The watchdog arms only once `Xcode build done.` appears, and from that instant
# the suite has FIRST_TEST_WATCHDOG_SECS to emit any reporter output. It cannot
# mask a real failure: it fires only while there is provably NO test activity,
# and it re-checks both the activity and the process at the deadline so a suite
# that started in the final poll window is never killed as a stall.
#
# It deliberately does NOT bound the BUILD. A build legitimately takes 7-11 min
# (measured) and a cold cache can take longer, and a hung or failed build is
# deterministic — retrying it hides it for another ten minutes. So a build that
# never completes runs into the caller's attempt timeout with the verdict still
# `unproven`, which the gate refuses to retry.
run_ios_test_with_watchdog() {
  local log="$1"
  ios_test_rc=0
  : > "${log}"

  spawn_ios_test "${log}"
  local test_pid=$!

  # Console follower. `flutter test`'s output no longer reaches the step log
  # directly (see spawn_ios_test), and a 45-minute step that prints nothing
  # until it ends is a real diagnosis cost. `tail -f` is a plain reader, so
  # unlike `tee` it holds no write end of anything the watchdog might kill.
  tail -f -n +1 "${log}" 2>/dev/null &
  local follower_pid=$!

  (
    local armed=0 waited=0
    while :; do
      sleep "${WATCHDOG_POLL_SECS}"
      # Process gone (connected and ran, or failed fast) — stand down.
      kill -0 "${test_pid}" 2>/dev/null || exit 0
      if (( armed == 0 )); then
        if LC_ALL=C grep -aqF -- "${IOS_BUILD_DONE_MARKER}" "${log}" 2>/dev/null; then
          armed=1
        fi
        continue
      fi
      # The suite spoke — the test is running; the caller's attempt timeout
      # governs from here, exactly as a post-connect hang does on Android.
      # (`if …; then exit 0; fi` rather than `pred && exit 0` for the same
      # reason run-single-avd-scenario.sh's watchdog uses it: the intent is a
      # branch, not a side effect. Both are errexit-safe — bash exempts every
      # command in an AND-list but the last — so this is style, not a fix.)
      if ios_log_test_activity "${log}"; then exit 0; fi
      waited=$(( waited + WATCHDOG_POLL_SECS ))
      (( waited >= FIRST_TEST_WATCHDOG_SECS )) || continue
      # Deadline. Re-check both facts so a run that just started, or just
      # exited in the last few microseconds, is never mislabelled a stall —
      # the boundary false-positive guard, as on Android.
      #
      # This activity check and the one above are deliberately REDUNDANT: they
      # run in the same loop iteration, so removing either alone changes
      # nothing observable and no hermetic fixture can separate them (the
      # window between them is microseconds). Removing BOTH is a real defect —
      # the watchdog would then kill running suites — and that IS covered:
      # fixture W2 fails the moment neither check remains.
      kill -0 "${test_pid}" 2>/dev/null || exit 0
      if ios_log_test_activity "${log}"; then exit 0; fi
      ios_stall_marker_line "${FIRST_TEST_WATCHDOG_SECS}" >> "${log}"
      kill -TERM "${test_pid}" 2>/dev/null || true
      sleep 5
      kill -KILL "${test_pid}" 2>/dev/null || true
      exit 0
    done
  ) &
  local watchdog_pid=$!

  wait "${test_pid}" 2>/dev/null || ios_test_rc=$?
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true
  # Give the follower a moment to drain the last writes (including a marker the
  # watchdog appended) before it is stopped.
  sleep 1
  kill "${follower_pid}" 2>/dev/null || true
  wait "${follower_pid}" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# --self-test — exercise THE WIRING, not the predicate.
#
# ios-flake-lib.sh's own self-test proves the classifier reads logs correctly.
# It cannot prove the watchdog ever produces such a log, ever fires, or ever
# stands down — and a watchdog that never fires silently reverts this lane to
# "the outer timeout kills it, nothing is classified, nothing is retried",
# while a watchdog that fires too eagerly kills running suites. Both are
# invisible to a fixture-only test.
#
# So this drives the REAL run_ios_test_with_watchdog against a stubbed
# `spawn_ios_test` — no simulator, no Xcode, no network — and then hands the
# resulting log to the REAL classifier. That last step is also the anti-drift
# proof: if the marker the watchdog writes ever stops being the marker the
# classifier requires, fixture W1 fails.
# ---------------------------------------------------------------------------
run_self_test() {
  # Drive the watchdog on a compressed clock. The deadline constants are
  # `readonly` on purpose (they gate a 45-minute step), so re-exec once with a
  # 2-second deadline rather than making them mutable for the test's benefit.
  if [[ "${HAVEN_IOS_SELF_TEST_REEXEC:-}" != "1" ]]; then
    HAVEN_IOS_SELF_TEST_REEXEC=1 \
    HAVEN_IOS_FIRST_TEST_WATCHDOG_SECS=2 \
    HAVEN_IOS_WATCHDOG_POLL_SECS=1 \
      exec bash "${BASH_SOURCE[0]}" --self-test
  fi

  local tmp fail=0 log
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN
  log="${tmp}/ios-test.log"

  # (W1) THE ADMITTED FLAKE — build completes, then the suite never speaks.
  #      The watchdog MUST fire, mark the log, and kill the run, and the REAL
  #      classifier MUST accept the result as retryable.
  spawn_ios_test() {
    {
      echo 'Running Xcode build...'
      echo 'Xcode build done.                                           400.0s'
      sleep 20
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if ! LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W1): the watchdog did NOT fire on a post-build stall" >&2
    fail=1
  fi
  if (( ios_test_rc == 0 )); then
    echo "SELF-TEST FAIL (W1): a killed stall reported success" >&2
    fail=1
  fi
  if ! ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W1): the classifier REJECTED the watchdog's own output" \
         "— the marker the watchdog writes and the marker the classifier requires" \
         "have drifted apart, so the one real iOS flake would stop being retried" >&2
    fail=1
  fi

  # (W2) A HEALTHY, SLOW SUITE — it speaks, then keeps working well past the
  #      watchdog deadline. The watchdog MUST stand down: killing a running
  #      suite at a fixed deadline would be a self-inflicted flake.
  spawn_ios_test() {
    {
      echo 'Xcode build done.                                           400.0s'
      echo '::group::✅ (setUpAll)'
      sleep 6
      echo '🎉 12 tests passed.'
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W2): the watchdog killed a RUNNING suite" >&2
    fail=1
  fi
  if (( ios_test_rc != 0 )); then
    echo "SELF-TEST FAIL (W2): a passing run reported rc=${ios_test_rc}" >&2
    fail=1
  fi

  # (W3) A GENUINE FAST FAILURE. The watchdog must not touch it, the true exit
  #      code must survive, and the classifier must refuse to retry it.
  spawn_ios_test() {
    {
      echo 'Xcode build done.                                           400.0s'
      echo '::group::❌ (setUpAll) (failed)'
      echo '::error::0 tests passed, 1 failed.'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if (( ios_test_rc != 1 )); then
    echo "SELF-TEST FAIL (W3): the real exit code was lost (got ${ios_test_rc})" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W3): a genuine test failure was classified as retryable" >&2
    fail=1
  fi

  # (W4) THE BUILD IS NOT WATCHED. A build that outlives the deadline must NOT
  #      arm the watchdog: a hung or failed build is deterministic, and retrying
  #      it hides it for another ten minutes.
  spawn_ios_test() {
    {
      echo 'Running pod install...'
      sleep 6
      echo 'Error running pod install'
      exit 1
    } > "$1" 2>&1 &
  }
  run_ios_test_with_watchdog "${log}" >/dev/null 2>&1
  if LC_ALL=C grep -aqF -- "${IOS_STALL_MARKER}" "${log}"; then
    echo "SELF-TEST FAIL (W4): the watchdog armed before the build finished" >&2
    fail=1
  fi
  if ios_log_is_launch_stall "${log}"; then
    echo "SELF-TEST FAIL (W4): a build-phase failure was classified as retryable" >&2
    fail=1
  fi

  if (( fail != 0 )); then
    echo "run-ios-sim-scenario.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "run-ios-sim-scenario.sh --self-test: all 4 watchdog fixtures passed" \
       "(a post-build stall is caught, marked and accepted by the classifier;" \
       "a running suite, a genuine failure and a slow build are left alone)."
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

SCENARIO_FILE="${1:-}"
SIM_UDID="${2:-}"
if [[ -z "${SCENARIO_FILE}" || -z "${SIM_UDID}" ]]; then
  echo "ERROR: usage: $0 <scenario-file> <simulator-udid>  |  $0 --self-test" >&2
  exit 2
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://localhost:7777}"
# S1: HAVEN_LIVE_SYNC is threaded per-STEP by the caller (env), never hardcoded
# in this shared script, so the same script serves BOTH the e2e_combined step
# (live-sync ON) and the ios_bg_mirror_test step (live-sync OFF — the M7 mirror
# must NOT start the engine).
#
# MANDATORY, with no default. The former `:-false` default was the last place a
# caller could decline to answer: e2e-profile.yml's iOS job took it silently
# while the Android job of the SAME lane took Dart's opposite default, so one
# lane ran one scenario on two receive paths and neither half said so
# (CI_HARDENING_BACKLOG.md A7). Both callers now set it per step, which is what
# S1 always intended — a per-step decision, not a fallback that happens to be
# safe today. Failing closed also means a NEW iOS step cannot inherit poll by
# accident the way a new Android build inherits live.
if [[ -z "${HAVEN_LIVE_SYNC:-}" ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC is not set." >&2
  echo "       This script compiles the receive path into the test build, so" >&2
  echo "       every calling STEP must state 'true' or 'false' in its env" >&2
  echo "       (S1 per-step scoping; CI_HARDENING_BACKLOG.md A7)." >&2
  exit 2
fi
if [[ ! "${HAVEN_LIVE_SYNC}" =~ ^(true|false)$ ]]; then
  echo "ERROR: HAVEN_LIVE_SYNC must be exactly 'true' or 'false' (got '${HAVEN_LIVE_SYNC}')." >&2
  exit 2
fi
readonly LIVE_SYNC="${HAVEN_LIVE_SYNC}"
# Single-engine guard for `flutter drive` (see main.dart): threaded per-STEP by
# the caller, like HAVEN_LIVE_SYNC, so e2e_combined can skip the M7 background
# init (which spawns a 2nd Flutter engine that collides with the driver) while
# the shared ios_bg_mirror step (which TESTS the background system) does not.
readonly E2E_NO_BACKGROUND="${HAVEN_E2E_NO_BACKGROUND:-false}"
readonly LOG_FILE="/tmp/flutter-ios-test.log"

# SCRIPT_DIR is set at the top of this file (the library source needs it).
readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

if [[ ! -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]]; then
  echo "ERROR: scenario file not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2
  exit 2
fi

cd "${HAVEN_DIR}"

# ---------------------------------------------------------------------------
# Retry gate (A6). `nick-fields/retry` will start attempt 2 on ANY non-zero
# exit, and it has no input that could be told otherwise — so the refusal has to
# live here, in the command it re-runs, keyed on the verdict the previous
# attempt left behind. Placed FIRST so a refused attempt costs seconds rather
# than another 10-minute Xcode build.
#
# Fails closed: only an attempt that reached classification AND proved the one
# admitted signature leaves `retryable`. Everything else — a genuine failure, a
# crash, an outer-timeout SIGKILL, a verdict too mangled to parse — stops here
# with the original exit code. See tooling/e2e/ci/ios-flake-lib.sh.
# ---------------------------------------------------------------------------
VERDICT_FILE="$(ios_retry_verdict_file "${SCENARIO_FILE}")"
readonly VERDICT_FILE
ios_retry_gate "${VERDICT_FILE}" || exit $?

echo "iOS E2E — scenario=${SCENARIO_FILE} udid=${SIM_UDID} relay=${RELAY_URL} live_sync=${LIVE_SYNC}"

# Optional Blossom URL passthrough (public-profile lane only). Appended to the
# flutter-test dart-defines ONLY when HAVEN_E2E_BLOSSOM_URL is set in the
# environment (the e2e-profile.yml iOS job sets it), so every OTHER iOS lane's
# compiled dart-defines stay byte-identical — this shared script must not
# change behaviour for the lanes that do not use Blossom.
EXTRA_DART_DEFINES=()
if [[ -n "${HAVEN_E2E_BLOSSOM_URL:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_BLOSSOM_URL="${HAVEN_E2E_BLOSSOM_URL}")
  echo "iOS E2E — blossom=${HAVEN_E2E_BLOSSOM_URL}"
fi

# Optional profile-plane relay passthrough (public-profile lane only), same
# opt-in shape as the Blossom URL above. These point kind-0 publish/fetch at the
# hermetic pool started by start-profile-relays.sh, which is DISJOINT from the
# circle relay in ${RELAY_URL} — a contaminated relay is subtracted from the
# pool by haven-core's contamination ledger, so reusing the circle relay for
# kind-0 would fail closed with PoolUnderflow.
if [[ -n "${HAVEN_E2E_PROFILE_RELAY:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_PROFILE_RELAY="${HAVEN_E2E_PROFILE_RELAY}")
  echo "iOS E2E — profile relay=${HAVEN_E2E_PROFILE_RELAY}"
fi
if [[ -n "${HAVEN_E2E_PROFILE_RELAYS:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_E2E_PROFILE_RELAYS="${HAVEN_E2E_PROFILE_RELAYS}")
  echo "iOS E2E — profile pool=${HAVEN_E2E_PROFILE_RELAYS}"
fi

# Optional real-GPS expectation passthrough (B4 lane only — set by
# tooling/e2e/ci/run-b4-ios-real-gps.sh), same opt-in shape as the two above, so
# every other iOS lane's compiled dart-defines stay byte-identical.
#
# These name the coordinates that lane seeded with `xcrun simctl location set`.
# They MUST reach the compiler: b4_ios_real_gps_test.dart has no default for
# them and fails closed when they are absent, precisely so it can never end up
# comparing a decrypt against a constant it chose itself. The values are not
# echoed — a seeded position is the payload that lane exists to prove is
# encrypted, and this log is uploaded as a CI artifact.
if [[ -n "${HAVEN_B4_GEO_LAT:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_B4_GEO_LAT="${HAVEN_B4_GEO_LAT}")
fi
if [[ -n "${HAVEN_B4_GEO_LON:-}" ]]; then
  EXTRA_DART_DEFINES+=(--dart-define=HAVEN_B4_GEO_LON="${HAVEN_B4_GEO_LON}")
fi
if [[ -n "${HAVEN_B4_GEO_TOLERANCE_DEG:-}" ]]; then
  EXTRA_DART_DEFINES+=(
    --dart-define=HAVEN_B4_GEO_TOLERANCE_DEG="${HAVEN_B4_GEO_TOLERANCE_DEG}"
  )
fi

# Clean slate — mirror the Android lane's force-stop + `adb uninstall`
# (run-single-avd-scenario.sh). This simulator is booted ONCE and reused across
# steps and both retry attempts, and `flutter test` does NOT guarantee a data
# wipe (a timeout-killed prior attempt never runs its "remove app on
# completion"). A `haven_mdk.db` left in the app's Documents container by a
# prior process is then opened by THIS process under a fresh, ephemeral
# in-memory test keyring whose key does not match the one that encrypted that
# file → MDK "Wrong encryption key: database cannot be decrypted", which
# deterministically fails live-sync engine start for EVERY scenario. Removing
# the app deletes that container so the first open mints a fresh key+DB pair.
# `|| true`: a not-yet-installed app is fine.
#
# OPT-OUT (HAVEN_E2E_IOS_SKIP_UNINSTALL=1): a caller that has ALREADY prepared
# the simulator — its own uninstall, install, and per-run `xcrun simctl privacy`
# grants — must be able to stop this line from erasing that preparation. A
# privacy grant is keyed by bundle id and does not survive an uninstall, so an
# unconditional wipe here would silently revert the B7 auth-tier lane
# (tooling/e2e/ci/run-b7-ios-auth-tier.sh) to "no authorization granted", which
# reads on the wire exactly like a passing run of a lane that proved nothing.
# Unset in every other lane, so their behaviour is unchanged.
if [[ "${HAVEN_E2E_IOS_SKIP_UNINSTALL:-}" == "1" ]]; then
  echo "iOS E2E — skipping the pre-run uninstall (HAVEN_E2E_IOS_SKIP_UNINSTALL=1):" \
       "the caller owns this simulator's install + privacy state."
else
  xcrun simctl uninstall "${SIM_UDID}" com.oblivioustech.haven >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Drive the integration test on the booted simulator.
#
# `flutter test <integration_test> -d <udid>` builds (debug), installs, runs,
# and reports — no separate `flutter drive` / test_driver indirection (which
# on iOS would need an IPA, not a simulator .app). The dart-define injects the
# relay URL the host relay is serving. The invocation itself lives in
# `spawn_ios_test` (near the top of this file) so the watchdog can supervise it
# and so --self-test can substitute a synthetic process for it.
# ---------------------------------------------------------------------------
set +e
run_ios_test_with_watchdog "${LOG_FILE}"
TEST_RC=${ios_test_rc}
set -e

# ---------------------------------------------------------------------------
# Security Rule #6: no key material may ever reach CI logs. Scan the captured
# output and FAIL the lane if anything secret-shaped is present, even if the
# scenario itself passed.
#
# Ordered BEFORE the retry classification on purpose: a leak is never
# infrastructure, and must never be re-rolled in the hope the next attempt keeps
# it out of the log.
# ---------------------------------------------------------------------------
if [[ -x "${SECRET_SCAN}" ]]; then
  if ! bash "${SECRET_SCAN}" "${LOG_FILE}"; then
    ios_retry_record "${VERDICT_FILE}" genuine 1 "secret-leak scan flagged the test log"
    echo "ERROR: secret-leak scan flagged the iOS test log" >&2
    exit 1
  fi
fi

if [[ "${TEST_RC}" -ne 0 ]]; then
  # ---------------------------------------------------------------------------
  # Classify, and record the verdict the NEXT attempt is gated on. The
  # classify-and-record step lives in the library so it is reachable from a
  # hermetic self-test (fixtures R1/R2) — an unconditional `retryable` here is
  # the blanket retry restored, and it must not be able to slip past CI.
  # ---------------------------------------------------------------------------
  if ios_record_failure_verdict "${VERDICT_FILE}" "${LOG_FILE}" "${TEST_RC}"; then
    echo "WARN: iOS e2e scenario '${SCENARIO_FILE}' hit a simulator" \
         "LAUNCH/ATTACH STALL (rc=${TEST_RC}) — the app built and installed but" \
         "the suite never emitted a single reporter line within" \
         "${FIRST_TEST_WATCHDOG_SECS}s, so no test code ran. This is the one" \
         "failure this lane retries; a retry may follow." >&2
  fi
  echo "ERROR: iOS e2e scenario '${SCENARIO_FILE}' failed (rc=${TEST_RC})" >&2
  exit "${TEST_RC}"
fi

# Passed — leave no verdict behind for a later step or a re-run to trip over.
ios_retry_clear "${VERDICT_FILE}"
echo "iOS E2E — PASSED"
