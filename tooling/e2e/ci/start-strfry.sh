#!/usr/bin/env bash
#
# Starts the hermetic strfry Nostr relay used by the E2E tests, then
# verifies that it actually stays up — not just that its port briefly
# opens during startup. The previous nc-only check was racy: the
# dockurr/strfry image opens the listening socket before calling
# `mdb_env_open()`, so a port probe passes even when strfry is about
# to crash because its LMDB env directory doesn't exist.
#
# Two things make this work:
#
# 1. We mount the checked-in `tooling/e2e/strfry.conf` over the
#    image's default config, so the db path strfry tries to open
#    (`/var/lib/strfry/strfry-db`) is exactly the path we bind-mount
#    a writable host directory at.
# 2. The health check requires container-running AND port-listening
#    AND a clean log (no `strfry error` string) before declaring
#    success.
#
# Why a checked-in script: see other tooling/e2e/ci/*.sh files —
# multi-line YAML scripts are fragile against inline-shell quirks.
#
# Usage:
#   bash tooling/e2e/ci/start-strfry.sh
#
# Optional env:
#   STRFRY_IMAGE         Docker image (default: dockurr/strfry:latest).
#                        Set the GitHub repo variable to a digest pin
#                        for supply-chain reproducibility.
#   STRFRY_DATA_DIR      Host path mounted at /var/lib/strfry inside
#                        the container (default: /tmp/strfry-data).
#   STRFRY_CONTAINER     Container name (default: strfry).
#   STRFRY_PORT          Host port to publish 7777 on (default: 7777).
#   STRFRY_READY_TIMEOUT Seconds to wait for the relay to come up
#                        (default: 60).

set -euo pipefail

readonly IMAGE="${STRFRY_IMAGE:-dockurr/strfry:latest}"
readonly DATA_DIR="${STRFRY_DATA_DIR:-/tmp/strfry-data}"
readonly CONTAINER="${STRFRY_CONTAINER:-strfry}"
readonly PORT="${STRFRY_PORT:-7777}"
readonly READY_TIMEOUT="${STRFRY_READY_TIMEOUT:-60}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${script_dir}/../strfry.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: strfry config not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# The image's default config points at a path the image itself
# doesn't `mkdir`. Pre-create the LMDB env directory on the host
# before the bind-mount so strfry's `mdb_env_open()` succeeds.
mkdir -p "${DATA_DIR}/strfry-db"
chmod -R 777 "${DATA_DIR}"

# Idempotent: remove any leftover container from a previous run so
# `docker run --name` doesn't collide.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

echo "Starting strfry: image=${IMAGE} port=${PORT} data=${DATA_DIR}"
docker run -d \
  --name "${CONTAINER}" \
  -p "${PORT}:7777" \
  -v "${DATA_DIR}:/var/lib/strfry" \
  -v "${CONFIG_FILE}:/etc/strfry.conf:ro" \
  "${IMAGE}" \
  > /dev/null

# Wait for the relay to BOTH stay running AND accept connections.
# Polling at 1 s intervals; total wait bounded by READY_TIMEOUT.
deadline=$(( SECONDS + READY_TIMEOUT ))
while (( SECONDS < deadline )); do
  if ! docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null \
       | grep -q true; then
    echo "ERROR: strfry container exited during startup. Logs:" >&2
    docker logs "${CONTAINER}" >&2 || true
    exit 1
  fi
  if nc -z 127.0.0.1 "${PORT}" 2>/dev/null; then
    # Don't trust a single port-open: strfry's image opens the
    # listener briefly before mdb_env_open(), so confirm after a
    # short delay that the container is still up AND no fatal
    # `strfry error` line has appeared in the logs.
    sleep 2
    if ! docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null \
         | grep -q true; then
      echo "ERROR: strfry exited shortly after opening port. Logs:" >&2
      docker logs "${CONTAINER}" >&2 || true
      exit 1
    fi
    if docker logs "${CONTAINER}" 2>&1 | grep -q '^strfry error'; then
      echo "ERROR: strfry logged a fatal error after startup:" >&2
      docker logs "${CONTAINER}" >&2 || true
      exit 1
    fi
    echo "strfry healthy: container running, port ${PORT} listening, no errors in logs."
    exit 0
  fi
  sleep 1
done

echo "ERROR: strfry never became reachable on port ${PORT} within ${READY_TIMEOUT}s. Logs:" >&2
docker logs "${CONTAINER}" >&2 || true
exit 1
