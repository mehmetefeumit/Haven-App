#!/usr/bin/env bash
#
# Tears down the hermetic profile-plane relay pool started by
# start-profile-relays.sh.
#
# Post-test counterpart to start-profile-relays.sh: the start script only cleans
# up a member whose OWN start failed (leaving healthy members running for the
# test), so this is what the workflow's `if: always()` teardown step invokes,
# pass or fail.
#
# Best-effort by design: teardown must never fail the job. Every member is torn
# down independently — one already-gone container or PID cannot stop the rest —
# and the script always exits 0. (`set -u` stays on to catch genuine scripting
# mistakes.)
#
# Usage:
#   stop-profile-relays.sh docker [port ...]   # Linux runner  (Android job)
#   stop-profile-relays.sh native [port ...]   # macOS runner  (iOS job)
#
# Ports default to "7778 7779 7780" and MUST match the ports the start script
# was given, so the container names / instance names line up.

set -uo pipefail

if [[ $# -ge 1 ]]; then
  MODE="$1"
  shift
else
  MODE=""
fi
readonly MODE

# Whitespace-separated string rather than an array: bash 3.2 (macOS runners)
# errors on expanding an empty array under `set -u`. Splitting is intentional.
PORTS="$*"
if [[ -z "${PORTS}" ]]; then
  PORTS="7778 7779 7780"
fi
readonly PORTS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

if [[ "${MODE}" != "docker" && "${MODE}" != "native" ]]; then
  # Teardown never fails the job, so an unusable mode is reported and skipped
  # rather than raised — the caller is an `if: always()` step.
  echo "[stop-profile-relays] usage: $0 <docker|native> [port ...] — nothing to do." >&2
  exit 0
fi

echo "[stop-profile-relays] mode=${MODE} ports=${PORTS}"

# shellcheck disable=SC2086 # intentional word splitting over the port list
for port in ${PORTS}; do
  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    echo "[stop-profile-relays] skipping invalid port '${port}'." >&2
    continue
  fi

  if [[ "${MODE}" == "docker" ]]; then
    STRFRY_CONTAINER="strfry-profile-${port}" \
    STRFRY_DATA_DIR="/tmp/strfry-profile-${port}-data" \
      bash "${SCRIPT_DIR}/stop-strfry.sh" || true
  else
    bash "${SCRIPT_DIR}/stop-local-relay.sh" "profile-${port}" || true
  fi
done

echo "[stop-profile-relays] profile-plane relay teardown complete."
exit 0
