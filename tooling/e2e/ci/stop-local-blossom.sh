#!/usr/bin/env bash
#
# Stops host-native Blossom servers started by start-local-blossom.sh: the
# instance on each port named, or every instance when none is.
#
# Best-effort and ALWAYS exits 0 so an `if: always()` teardown step can never
# turn a green run red.
#
# Usage: stop-local-blossom.sh [<port>...]

set -uo pipefail

if (( $# == 0 )); then
  for f in /tmp/haven-local-blossom-*.pid; do
    [[ -f "${f}" ]] || continue
    kill "$(cat "${f}" 2>/dev/null)" 2>/dev/null || true
    rm -f "${f}"
  done
  pkill -f 'haven-local-blossom --port ' 2>/dev/null || true
  exit 0
fi

for port in "$@"; do
  pid_file="/tmp/haven-local-blossom-${port}.pid"
  if [[ -f "${pid_file}" ]]; then
    kill "$(cat "${pid_file}" 2>/dev/null)" 2>/dev/null || true
    rm -f "${pid_file}"
  fi
  # The binary is started with `--port <port>` first, so this names one
  # instance even when the PID file was lost.
  pkill -f "haven-local-blossom --port ${port}( |$)" 2>/dev/null || true
done
exit 0
