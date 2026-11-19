#!/usr/bin/env bash
#
# Builds (release) and starts one host-native Blossom server
# (tooling/e2e/local-blossom), then blocks until every port it serves answers
# HTTP.
#
# The public-profile lane runs it on both platforms: as the PRIMARY upload
# server in the `primal` profile (a mimic of blossom.primal.net: padded
# standard base64 auth only, a verified kind-24242 event, and GET answered
# with a 302 to a second "CDN" port), and on iOS also as the fallback in the
# `reference` profile (macOS runners have no Linux Docker for the hzrd149
# container the Android jobs use there). The emulator reaches it at
# http://10.0.2.2:<port>, the simulator at http://localhost:<port>; both are
# host loopback, which the egress guard admits.
#
# Usage:
#   start-local-blossom.sh <port> [--profile primal|reference] [--cdn-port N] [--control]
#     (defaults: port 3000, profile reference)
#
# One instance per port: the PID and log files are keyed by it
# (/tmp/haven-local-blossom-<port>.{pid,log}, read by stop-local-blossom.sh),
# and a start first stops that port's previous instance — a retried attempt
# must not see blobs, a fault or a clock skew a failed one left behind — and
# no other.

set -euo pipefail

readonly PORT="${1:-3000}"
[[ "${PORT}" =~ ^[0-9]+$ ]] || { echo "ERROR: the first argument is the port" >&2; exit 2; }
shift || true
CDN_PORT=''
args=(--port "${PORT}")
while (( $# )); do
  case "$1" in
    --profile) args+=(--profile "$2"); shift 2 ;;
    --cdn-port) CDN_PORT="$2"; args+=(--cdn-port "$2"); shift 2 ;;
    --control) args+=(--control); shift ;;
    *) echo "ERROR: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly CRATE_DIR="${SCRIPT_DIR}/../local-blossom"
readonly PID_FILE="/tmp/haven-local-blossom-${PORT}.pid"
readonly LOG_FILE="/tmp/haven-local-blossom-${PORT}.log"
readonly READY_SECS=30

bash "${SCRIPT_DIR}/stop-local-blossom.sh" "${PORT}" >/dev/null 2>&1 || true

echo "Building host-native blossom server (release)..."
cargo build --release --manifest-path "${CRATE_DIR}/Cargo.toml"
readonly BIN="${CRATE_DIR}/target/release/haven-local-blossom"

echo "Starting blossom server on 127.0.0.1:${PORT} (${args[*]:2})..."
nohup "${BIN}" "${args[@]}" >"${LOG_FILE}" 2>&1 &
echo $! >"${PID_FILE}"

# Ready when the process has bound every port (one "listening on" line each)
# and each answers HTTP (curl exit 0 on any status: an unknown path is 404).
want=1
ports=("${PORT}")
if [[ -n "${CDN_PORT}" ]]; then want=2; ports+=("${CDN_PORT}"); fi
deadline=$(( SECONDS + READY_SECS ))
while (( SECONDS < deadline )); do
  if ! kill -0 "$(cat "${PID_FILE}")" 2>/dev/null; then
    echo "ERROR: the blossom server on port ${PORT} exited during startup" >&2
    cat "${LOG_FILE}" >&2 2>/dev/null || true
    exit 1
  fi
  up=0
  if (( $(grep -c 'listening on' "${LOG_FILE}" 2>/dev/null || true) == want )); then
    up=1
    for p in "${ports[@]}"; do
      curl -s -o /dev/null -m 5 "http://127.0.0.1:${p}/" || up=0
    done
  fi
  if (( up )); then
    echo "Blossom server is answering HTTP on 127.0.0.1:${ports[*]}."
    exit 0
  fi
  sleep 1
done

echo "ERROR: the blossom server on port ${PORT} did not come up within ${READY_SECS}s" >&2
cat "${LOG_FILE}" >&2 2>/dev/null || true
exit 1
