#!/usr/bin/env bash
#
# Builds (release) and starts the host-native Nostr relay used by the iOS
# E2E lane, then blocks until it accepts connections.
#
# macOS GitHub runners have no Linux Docker daemon, so the Android lane's
# `strfry` container cannot run there; this binary (tooling/e2e/local-relay)
# is the drop-in equivalent, built from the same nostr 0.44 wire stack the
# app uses. The simulator reaches it at ws://localhost:<port>.
#
# Usage: start-local-relay.sh [port] [instance]   (default: 7777 default)
#
# `instance` names ONE relay process so several can run side by side — the
# profile lane needs a circle relay AND a disjoint profile-plane pool on the
# same runner (see start-profile-relays.sh). The DEFAULT instance keeps the
# historical file names byte-for-byte, so every other iOS lane is unaffected:
#
#   default          → /tmp/haven-local-relay.pid  /tmp/haven-local-relay.log
#   <name>           → /tmp/haven-local-relay-<name>.pid  (…-<name>.log)
#
# Each process is also launched with a `--haven-relay-instance=<name>` argv
# marker so teardown can `pkill -f` exactly ONE instance instead of every relay
# on the box. The relay binary reads its port from HAVEN_RELAY_PORT and ignores
# argv entirely (tooling/e2e/local-relay/src/main.rs), so the marker is inert.

set -euo pipefail

readonly PORT="${1:-7777}"
readonly INSTANCE="${2:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-relay"

if [[ ! "${INSTANCE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: instance name '${INSTANCE}' must match [A-Za-z0-9._-]+" >&2
  exit 2
fi

# The default instance keeps the legacy paths so the other iOS lanes' diagnostic
# steps (which read /tmp/haven-local-relay.log by name) keep working unchanged.
if [[ "${INSTANCE}" == "default" ]]; then
  readonly PID_FILE="/tmp/haven-local-relay.pid"
  readonly LOG_FILE="/tmp/haven-local-relay.log"
else
  readonly PID_FILE="/tmp/haven-local-relay-${INSTANCE}.pid"
  readonly LOG_FILE="/tmp/haven-local-relay-${INSTANCE}.log"
fi

# Restart semantics: stop any relay already running FOR THIS INSTANCE (a prior
# CI retry attempt, or the build-before-boot warm-up start) so each invocation
# yields a CLEAN in-memory store — a retried attempt must not see leftover
# events from a failed prior one. Scoped to the instance so restarting the
# circle relay cannot take the profile-plane pool down with it. Best-effort; the
# cargo build below is a cache hit on re-runs, so the restart is fast.
bash "${SCRIPT_DIR}/stop-local-relay.sh" "${INSTANCE}" >/dev/null 2>&1 || true

echo "Building host-native relay (release)..."
cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml"
readonly BIN="${CRATE_DIR}/target/release/haven-local-relay"

echo "Starting relay instance '${INSTANCE}' on 127.0.0.1:${PORT}..."
HAVEN_RELAY_PORT="${PORT}" nohup "${BIN}" "--haven-relay-instance=${INSTANCE}" \
  >"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"

# Wait up to 30s for the relay to accept TCP connections. nc is preinstalled
# on GitHub macOS runners.
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "${PORT}" 2>/dev/null; then
    echo "Relay '${INSTANCE}' is accepting connections on 127.0.0.1:${PORT}."
    cat "${LOG_FILE}" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done

echo "ERROR: relay '${INSTANCE}' did not come up on port ${PORT} within 30s" >&2
cat "${LOG_FILE}" >&2 2>/dev/null || true
exit 1
