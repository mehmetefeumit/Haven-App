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
# Usage: start-local-relay.sh [port]   (default 7777)
#
# Writes the relay PID to /tmp/haven-local-relay.pid (read by
# stop-local-relay.sh) and its output to /tmp/haven-local-relay.log.

set -euo pipefail

readonly PORT="${1:-7777}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-relay"
readonly PID_FILE="/tmp/haven-local-relay.pid"
readonly LOG_FILE="/tmp/haven-local-relay.log"

# Restart semantics: stop any relay already running (a prior CI retry attempt,
# or the build-before-boot warm-up start) so each invocation yields a CLEAN
# in-memory store — a retried attempt must not see leftover events from a
# failed prior one. Best-effort; the cargo build below is a cache hit on
# re-runs, so the restart is fast.
bash "${SCRIPT_DIR}/stop-local-relay.sh" >/dev/null 2>&1 || true

echo "Building host-native relay (release)..."
cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml"
readonly BIN="${CRATE_DIR}/target/release/haven-local-relay"

echo "Starting relay on 127.0.0.1:${PORT}..."
HAVEN_RELAY_PORT="${PORT}" nohup "${BIN}" >"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"

# Wait up to 30s for the relay to accept TCP connections. nc is preinstalled
# on GitHub macOS runners.
for _ in $(seq 1 30); do
  if nc -z 127.0.0.1 "${PORT}" 2>/dev/null; then
    echo "Relay is accepting connections on 127.0.0.1:${PORT}."
    cat "${LOG_FILE}" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done

echo "ERROR: relay did not come up on port ${PORT} within 30s" >&2
cat "${LOG_FILE}" >&2 2>/dev/null || true
exit 1
