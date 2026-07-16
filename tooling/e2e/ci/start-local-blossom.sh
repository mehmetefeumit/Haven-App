#!/usr/bin/env bash
#
# Builds (release) and starts the host-native Blossom media server used by the
# public-profile iOS E2E lane, then blocks until it answers HTTP.
#
# macOS GitHub runners have no Linux Docker daemon, so the Android lane's
# `ghcr.io/hzrd149/blossom-server` container cannot run here; this binary
# (tooling/e2e/local-blossom) is the drop-in BUD-02 equivalent. The simulator
# reaches it at http://localhost:<port> (it shares the host network namespace —
# no `10.0.2.2` alias). The profile-picture path targets it via the
# `HAVEN_E2E_BLOSSOM_URL` dart-define.
#
# Mirrors start-local-relay.sh: release build, PID file, log file, bounded
# readiness poll.
#
# Usage: start-local-blossom.sh [port]   (default 3000)
#
# Writes the server PID to /tmp/haven-local-blossom.pid (read by
# stop-local-blossom.sh) and its output to /tmp/haven-local-blossom.log.

set -euo pipefail

readonly PORT="${1:-3000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-blossom"
readonly PID_FILE="/tmp/haven-local-blossom.pid"
readonly LOG_FILE="/tmp/haven-local-blossom.log"

# Restart semantics: stop any server already running (a prior CI retry attempt,
# or the build-before-boot warm-up start) so each invocation yields a CLEAN
# in-memory blob store — a retried attempt must not see leftover blobs from a
# failed prior one. Best-effort; the cargo build below is a cache hit on
# re-runs, so the restart is fast.
bash "${SCRIPT_DIR}/stop-local-blossom.sh" >/dev/null 2>&1 || true

echo "Building host-native blossom server (release)..."
cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml"
readonly BIN="${CRATE_DIR}/target/release/haven-local-blossom"

echo "Starting blossom server on 127.0.0.1:${PORT}..."
HAVEN_BLOSSOM_PORT="${PORT}" nohup "${BIN}" "${PORT}" >"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"

# Wait up to 30s for the server to answer HTTP. The binary prints
# "[haven-local-blossom] listening on ..." right after it binds; we confirm
# BOTH that line AND a live HTTP response (curl exit 0 on any status — the root
# route legitimately answers 404). curl is preinstalled on GitHub macOS
# runners.
for _ in $(seq 1 30); do
  if grep -q "listening on" "${LOG_FILE}" 2>/dev/null \
     && curl -s -o /dev/null -m 5 "http://127.0.0.1:${PORT}/"; then
    echo "Blossom server is answering HTTP on 127.0.0.1:${PORT}."
    cat "${LOG_FILE}" 2>/dev/null || true
    exit 0
  fi
  sleep 1
done

echo "ERROR: blossom server did not come up on port ${PORT} within 30s" >&2
cat "${LOG_FILE}" >&2 2>/dev/null || true
exit 1
