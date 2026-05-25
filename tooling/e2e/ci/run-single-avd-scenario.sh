#!/usr/bin/env bash
#
# Runs a single-instance Haven E2E scenario inside the
# `reactivecircus/android-emulator-runner@v2` action's `script:`
# block. The action has already booted one emulator on port 5554
# before this script runs.
#
# Why a checked-in script instead of an inline YAML script: the
# action executes multi-line `script:` blocks one line per `sh -c`
# invocation, so `cd haven`, shell variable assignments, and
# backgrounded process IDs all evaporate between lines. Wrapping the
# entire script in a single `bash <path>` invocation avoids that.
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
#   - Runs `flutter test` against the connected emulator.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <scenario-file>" >&2
  exit 2
fi

readonly SCENARIO_FILE="$1"
readonly RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"

# Resolve the haven/ project directory relative to this script's
# location so the workflow doesn't have to care about its cwd.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"
readonly HAVEN_DIR="${repo_root}/haven"

if [[ ! -f "${HAVEN_DIR}/pubspec.yaml" ]]; then
  echo "ERROR: Haven project not found at ${HAVEN_DIR}" >&2
  exit 1
fi

cd "${HAVEN_DIR}"

# Capture logcat to a file so the failure-artifact step can pick it
# up; truncate first so we only get this scenario's slice. The
# trap kills the background logcat on any exit (success, failure,
# signal) so the file is always cleanly flushed.
adb logcat -c
adb logcat -v threadtime > /tmp/adb-logcat.log &
readonly LOGCAT_PID=$!

cleanup() {
  if kill -0 "${LOGCAT_PID}" 2>/dev/null; then
    kill "${LOGCAT_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

flutter test \
  --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
  "${SCENARIO_FILE}"
