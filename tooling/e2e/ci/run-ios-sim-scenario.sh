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
#
# Side effects:
#   - Writes /tmp/flutter-ios-test.log (uploaded as a CI failure artifact).
#
# Exit status: the `flutter test` exit code (0 = scenario passed).

set -euo pipefail

SCENARIO_FILE="${1:-}"
SIM_UDID="${2:-}"
if [[ -z "${SCENARIO_FILE}" || -z "${SIM_UDID}" ]]; then
  echo "ERROR: usage: $0 <scenario-file> <simulator-udid>" >&2
  exit 2
fi

readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://localhost:7777}"
readonly LOG_FILE="/tmp/flutter-ios-test.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly REPO_ROOT="${SCRIPT_DIR}/../../.."
readonly HAVEN_DIR="${REPO_ROOT}/haven"
readonly SECRET_SCAN="${SCRIPT_DIR}/scan-logs-for-secrets.sh"

if [[ ! -f "${HAVEN_DIR}/${SCENARIO_FILE}" ]]; then
  echo "ERROR: scenario file not found: ${HAVEN_DIR}/${SCENARIO_FILE}" >&2
  exit 2
fi

cd "${HAVEN_DIR}"

echo "iOS E2E — scenario=${SCENARIO_FILE} udid=${SIM_UDID} relay=${RELAY_URL}"

# ---------------------------------------------------------------------------
# Drive the integration test on the booted simulator.
#
# `flutter test <integration_test> -d <udid>` builds (debug), installs, runs,
# and reports — no separate `flutter drive` / test_driver indirection (which
# on iOS would need an IPA, not a simulator .app). The dart-define injects the
# relay URL the host relay is serving. `tee` mirrors the Dart test-reporter
# output (which phase failed, the EXCEPTION block, the stack) into the log
# artifact while preserving `flutter test`'s exit status via PIPESTATUS.
# ---------------------------------------------------------------------------
set +e
flutter test "${SCENARIO_FILE}" \
  -d "${SIM_UDID}" \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  2>&1 | tee "${LOG_FILE}"
TEST_RC=${PIPESTATUS[0]}
set -e

# ---------------------------------------------------------------------------
# Security Rule #6: no key material may ever reach CI logs. Scan the captured
# output and FAIL the lane if anything secret-shaped is present, even if the
# scenario itself passed.
# ---------------------------------------------------------------------------
if [[ -x "${SECRET_SCAN}" ]]; then
  if ! bash "${SECRET_SCAN}" "${LOG_FILE}"; then
    echo "ERROR: secret-leak scan flagged the iOS test log" >&2
    exit 1
  fi
fi

if [[ "${TEST_RC}" -ne 0 ]]; then
  echo "ERROR: iOS e2e scenario '${SCENARIO_FILE}' failed (rc=${TEST_RC})" >&2
  exit "${TEST_RC}"
fi

echo "iOS E2E — PASSED"
