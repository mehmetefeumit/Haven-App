#!/usr/bin/env bash
#
# Stops the host-native relay started by start-local-relay.sh.
#
# Usage: stop-local-relay.sh [instance]   (default: default)
#
# `instance` must match the one start-local-relay.sh was given. The profile lane
# runs SEVERAL relays on one runner (a circle relay plus a disjoint profile-plane
# pool — see start-profile-relays.sh), so teardown is scoped to one instance:
# killing every `haven-local-relay` process unconditionally would take the other
# plane's relays down mid-test.
#
# Best-effort and ALWAYS exits 0 so an `if: always()` teardown step can never
# turn a green run red.

set -uo pipefail

readonly INSTANCE="${1:-default}"

if [[ ! "${INSTANCE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[stop-local-relay] ignoring invalid instance name '${INSTANCE}'." >&2
  exit 0
fi

# The default instance keeps the legacy PID path (see start-local-relay.sh).
if [[ "${INSTANCE}" == "default" ]]; then
  readonly PID_FILE="/tmp/haven-local-relay.pid"
else
  readonly PID_FILE="/tmp/haven-local-relay-${INSTANCE}.pid"
fi

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]]; then
    kill "${PID}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}"
fi

# Belt-and-suspenders in case the PID file was lost: match the argv marker
# start-local-relay.sh launches every instance with, so this kills THIS
# instance and no other.
pkill -f "haven-relay-instance=${INSTANCE}" 2>/dev/null || true

# Legacy sweep: catch a relay started before instance markers existed (or by a
# hand-run of the binary). Only for the default instance, and ONLY when no NAMED
# instance is registered — with a named instance live, an unscoped pkill would
# kill the other plane's relays, which is exactly what the scoping above exists
# to prevent.
#
# The pattern is the BINARY PATH rather than the bare name so it still matches
# every process this repo ever launched as a relay, without matching a shell
# that merely mentions `haven-local-relay` on its command line (that collateral
# is real: a wrapper running these very scripts can carry the bare name).
if [[ "${INSTANCE}" == "default" ]]; then
  if ! ls /tmp/haven-local-relay-*.pid >/dev/null 2>&1; then
    pkill -f 'local-relay/target/release/haven-local-relay' 2>/dev/null || true
  fi
fi

exit 0
