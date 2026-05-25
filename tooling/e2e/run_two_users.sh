#!/usr/bin/env bash
# Local two-AVD scenario driver — mirrors the CI flow for scenario_02+.
#
# Expects the developer to have already booted two devices reachable via
# `flutter devices`. Names the roles "alice" and "bob"; the dart-define
# routes each Flutter test process to its half of the coordinated flow.
#
# Usage:
#   tooling/e2e/run_two_users.sh <scenario_file> <alice_device_id> <bob_device_id>
#
# Example (two AVDs booted manually, named pixel_alice / pixel_bob):
#   $ANDROID_HOME/emulator/emulator -avd pixel_alice -port 5554 &
#   $ANDROID_HOME/emulator/emulator -avd pixel_bob   -port 5556 &
#   adb wait-for-device
#   tooling/e2e/run_two_users.sh \
#     integration_test/e2e/scenario_02_invitation_accept.dart \
#     emulator-5554 \
#     emulator-5556
#
# Assumes strfry is already running on the host (use
# `scripts/run_e2e_local.sh relay-up` first).
#
# Environment overrides:
#   HAVEN_E2E_RELAY  Override the dart-define passed to flutter test
#                    (default: ws://10.0.2.2:7777).

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 <scenario_file> <alice_device_id> <bob_device_id>" >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HAVEN_DIR="${REPO_ROOT}/haven"

SCENARIO="$1"
ALICE_DEVICE="$2"
BOB_DEVICE="$3"
RELAY_URL="${HAVEN_E2E_RELAY:-ws://10.0.2.2:7777}"

log() {
  printf '\033[1;34m[run_two_users]\033[0m %s\n' "$*"
}

# Sanity-check both devices.
for dev in "${ALICE_DEVICE}" "${BOB_DEVICE}"; do
  if ! flutter --no-version-check devices --machine 2>/dev/null \
       | grep -q "\"id\":\"${dev}\""; then
    echo "ERROR: device '${dev}' not visible to flutter devices." >&2
    flutter devices >&2
    exit 1
  fi
done

ALICE_LOG="$(mktemp -t haven-e2e-alice.XXXXXX.log)"
BOB_LOG="$(mktemp -t haven-e2e-bob.XXXXXX.log)"

log "Launching Alice on ${ALICE_DEVICE} (log: ${ALICE_LOG})"
(
  cd "${HAVEN_DIR}"
  flutter test \
    --device-id "${ALICE_DEVICE}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_E2E_ROLE=alice \
    "${SCENARIO}"
) > "${ALICE_LOG}" 2>&1 &
ALICE_PID=$!

# Stagger Bob's launch so Alice's APK build + install finishes before
# Bob's build starts. Both `flutter test` invocations write to the same
# haven/build/ directory; serial builds avoid an APK-overwrite race.
# Tests still run in parallel during execution — the relay coordinates.
log "Sleeping 120s to serialize APK builds..."
sleep 120

log "Launching Bob on ${BOB_DEVICE} (log: ${BOB_LOG})"
(
  cd "${HAVEN_DIR}"
  flutter test \
    --device-id "${BOB_DEVICE}" \
    --dart-define=HAVEN_E2E_RELAY="${RELAY_URL}" \
    --dart-define=HAVEN_E2E_ROLE=bob \
    "${SCENARIO}"
) > "${BOB_LOG}" 2>&1 &
BOB_PID=$!

# Wait for both processes; capture exit codes independently.
set +e
wait "${ALICE_PID}"; ALICE_EXIT=$?
wait "${BOB_PID}";   BOB_EXIT=$?
set -e

log "===== Alice output (${ALICE_DEVICE}) ====="
cat "${ALICE_LOG}"
log "===== Bob output (${BOB_DEVICE}) ====="
cat "${BOB_LOG}"
log "===== Exit codes: alice=${ALICE_EXIT} bob=${BOB_EXIT} ====="

if [[ ${ALICE_EXIT} -ne 0 || ${BOB_EXIT} -ne 0 ]]; then
  log "FAILED"
  exit 1
fi
log "OK"
