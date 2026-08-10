#!/usr/bin/env bash
#
# Stops the recording wire proxy started by start-wire-proxy.sh.
#
# Usage: stop-wire-proxy.sh [instance]   (default: default)
#
# `instance` must match the one start-wire-proxy.sh was given. A lane may run
# several proxies (one per relay plane), so teardown is scoped to one instance:
# killing every `haven-wire-proxy` unconditionally would take another plane's
# recorder down mid-test and silently truncate its journal.
#
# Sends SIGTERM, not SIGKILL, so the process can print its shutdown summary
# ("N connection(s), N record(s) observed, N line(s) written [— DEGRADED]").
# That line is the only place a run says whether its instrument stayed healthy,
# and it is what a fail-closed oracle cross-checks against the journal.
#
# It removes the pid file and the journal CLAIM, and deliberately NOT the
# MLS-group-id sidecar — see the note at the bottom of this file.
#
# Best-effort and ALWAYS exits 0 so an `if: always()` teardown step can never
# turn a green run red.

set -uo pipefail

readonly INSTANCE="${1:-default}"

if [[ ! "${INSTANCE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[stop-wire-proxy] ignoring invalid instance name '${INSTANCE}'." >&2
  exit 0
fi

readonly RUN_DIR="${HAVEN_WIRE_PROXY_RUN_DIR:-/tmp}"

if [[ "${INSTANCE}" == "default" ]]; then
  readonly PID_FILE="${RUN_DIR}/haven-wire-proxy.pid"
  readonly LOG_FILE="${RUN_DIR}/haven-wire-proxy.log"
  readonly CLAIM_FILE="${RUN_DIR}/haven-wire-proxy.journalpath"
  readonly MLS_GROUP_ID_FILE="${RUN_DIR}/haven-wire-proxy.mlsgroupid"
else
  readonly PID_FILE="${RUN_DIR}/haven-wire-proxy-${INSTANCE}.pid"
  readonly LOG_FILE="${RUN_DIR}/haven-wire-proxy-${INSTANCE}.log"
  readonly CLAIM_FILE="${RUN_DIR}/haven-wire-proxy-${INSTANCE}.journalpath"
  readonly MLS_GROUP_ID_FILE="${RUN_DIR}/haven-wire-proxy-${INSTANCE}.mlsgroupid"
fi

if [[ -f "${PID_FILE}" ]]; then
  PID="$(cat "${PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${PID:-}" ]]; then
    kill "${PID}" 2>/dev/null || true
    # Give the shutdown summary a moment to reach the log before the fallback
    # pkill below (or the runner teardown) removes the process.
    for _ in 1 2 3 4 5; do
      kill -0 "${PID}" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -f "${PID_FILE}"
fi

# Belt-and-suspenders in case the PID file was lost: match the argv marker
# start-wire-proxy.sh launches every instance with, so this kills THIS instance
# and no other.
pkill -f "haven-wire-proxy-instance=${INSTANCE}" 2>/dev/null || true

# Release this instance's journal claim. The start script also checks liveness,
# so a claim left behind by a crash is inert either way; dropping it here just
# keeps /tmp honest.
rm -f "${CLAIM_FILE}"

# The MLS-GROUP-ID SIDECAR IS DELIBERATELY LEFT IN PLACE. Do not add an `rm -f`
# for it here.
#
# It carries the REAL MLS group ids the device declared, and the lane reads it
# AFTER teardown — the oracle that asserts Security Rule 4 (`--mls-group-id` in
# check-wire-correlation.sh) runs as a later step, and deleting the file here
# would leave it with an empty needle set. It would then scan the journal for
# nothing, find nothing, and report a clean Rule-4 result it never actually
# checked. start-wire-proxy.sh rotates the file at the START of the next run,
# which is the right end of the lifecycle for it.
#
# Its COUNT is worth surfacing, its CONTENTS never (Security Rule 6): a lane
# that recorded zero ids has no ground truth, and that must be visible to
# someone reading an otherwise green run.
if [[ -f "${MLS_GROUP_ID_FILE}" ]]; then
  echo "[stop-wire-proxy] $(wc -l <"${MLS_GROUP_ID_FILE}" 2>/dev/null || echo 0)" \
    "MLS group id(s) kept in ${MLS_GROUP_ID_FILE} (host-only — NEVER upload it)."
else
  echo "[stop-wire-proxy] NOTE: no MLS group id sidecar at ${MLS_GROUP_ID_FILE};" \
    "an oracle asserting Security Rule 4 has no ground truth for this run." >&2
fi

# Surface the shutdown summary in the step log. A run whose recorder went
# DEGRADED must say so where a human reading a green lane will see it.
if [[ -f "${LOG_FILE}" ]]; then
  echo "[stop-wire-proxy] final lines of ${LOG_FILE}:"
  tail -n 5 "${LOG_FILE}" 2>/dev/null || true
fi

exit 0
