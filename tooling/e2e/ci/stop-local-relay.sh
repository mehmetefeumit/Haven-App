#!/usr/bin/env bash
#
# Stops the host-native relay started by start-local-relay.sh.
#
# Best-effort and ALWAYS exits 0 so an `if: always()` teardown step can never
# turn a green run red.

set -uo pipefail

readonly PID_FILE="/tmp/haven-local-relay.pid"

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]]; then
    kill "${PID}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
fi

# Belt-and-suspenders in case the PID file was lost.
pkill -f haven-local-relay 2>/dev/null || true

exit 0
