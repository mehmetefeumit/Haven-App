#!/usr/bin/env bash
#
# Starts the hermetic Blossom media server used by the public-profile E2E
# lane (Android job), then verifies it actually accepts HTTP before
# declaring success — not just that its TCP port briefly opens.
#
# The Android emulator reaches this server at `http://10.0.2.2:3000`
# (host-loopback alias); the profile-picture upload/download path targets it
# via the `HAVEN_E2E_BLOSSOM_URL` dart-define.
#
# It runs the same pinned `ghcr.io/hzrd149/blossom-server` image White Noise
# uses (whitenoise-rs/docker-compose.yml), bind-mounting the checked-in
# `tooling/e2e/blossom-server-config.yml` over the image's default config
# (local filesystem storage, discovery disabled, permissive uploads — see that
# file's header).
#
# Mirrors start-strfry.sh precisely: pinned-digest pull with bounded retry +
# linear backoff, failure-only teardown trap, a health check that requires
# container-running AND an HTTP response, and `docker logs` capture on failure.
#
# Why a checked-in script: see the other tooling/e2e/ci/*.sh files —
# multi-line YAML scripts are fragile against inline-shell quirks.
#
# Usage:
#   bash tooling/e2e/ci/start-blossom.sh
#
# Optional env:
#   BLOSSOM_IMAGE         Docker image. Defaults to the immutable digest pin
#                         of `ghcr.io/hzrd149/blossom-server` that White Noise
#                         pins (whitenoise-rs/docker-compose.yml). The CI
#                         workflow passes the same digest (or the BLOSSOM_IMAGE
#                         repo variable when set); override for local runs.
#   BLOSSOM_DATA_DIR      Host path mounted at /app/data inside the container
#                         (default: /tmp/blossom-data).
#   BLOSSOM_CONTAINER     Container name (default: blossom).
#   BLOSSOM_PORT          Host port to publish 3000 on (default: 3000).
#   BLOSSOM_READY_TIMEOUT Seconds to wait for the server to come up
#                         (default: 60).
#   BLOSSOM_PULL_ATTEMPTS Number of `docker pull` attempts (linear backoff)
#                         before giving up on a transient registry error
#                         (default: 5).

set -euo pipefail

# Immutable digest pin of `ghcr.io/hzrd149/blossom-server`, taken verbatim
# from whitenoise-rs/docker-compose.yml (the `blossom:` service). A digest pin
# is preferred over a floating tag so the hermetic server can't silently change
# between runs. Re-verify against WN's compose file when bumping.
readonly IMAGE="${BLOSSOM_IMAGE:-ghcr.io/hzrd149/blossom-server@sha256:efef9fa3ef47934aff586dd2161f221bd9549f0ace4c3432f65e1afb5d3f4d0a}"
readonly DATA_DIR="${BLOSSOM_DATA_DIR:-/tmp/blossom-data}"
readonly CONTAINER="${BLOSSOM_CONTAINER:-blossom}"
readonly PORT="${BLOSSOM_PORT:-3000}"
readonly READY_TIMEOUT="${BLOSSOM_READY_TIMEOUT:-60}"
readonly PULL_ATTEMPTS="${BLOSSOM_PULL_ATTEMPTS:-5}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${script_dir}/../blossom-server-config.yml"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: blossom config not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# Failure-only teardown. On a SUCCESSFUL start this script exits 0 with the
# container still running in the background for the test step to use, so we
# must NOT tear down on a clean exit. We only clean up a half-started container
# + its data dir when startup FAILS, so a broken attempt can't leak a stale
# container or stale blobs into a later run on a reused self-hosted runner. The
# post-test teardown lives in the workflow's `if: always()` step
# (stop-blossom.sh).
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    echo "start-blossom.sh failed (rc=${rc}); cleaning up half-started server." >&2
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    rm -rf "${DATA_DIR}" || true
  fi
  return "${rc}"
}
trap on_exit EXIT

# Idempotent: remove any leftover container from a previous run so
# `docker run --name` doesn't collide. Done BEFORE wiping the data dir so a
# still-running container can't be holding the dir open.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

# Blob isolation: wipe the host data dir before recreating it, so a blob left
# behind by a crashed prior run (the synthetic actors use deterministic seeds)
# can't be served back as stale state and corrupt the next run.
rm -rf "${DATA_DIR}"
mkdir -p "${DATA_DIR}/blobs"
chmod -R 777 "${DATA_DIR}"

# Pre-pull the pinned image with a bounded retry + linear backoff. `docker run`
# below would otherwise pull implicitly with NO retry, so a single transient
# registry failure (HTTP 5xx / rate limit) fails the whole E2E lane. The sha256
# digest pin is unchanged, so every pull is still content-verified — this only
# adds resilience to a flaky registry (mirrors start-strfry.sh + the repo's
# cargo-download retry hardening).
pull_image() {
  local attempt backoff
  for (( attempt = 1; attempt <= PULL_ATTEMPTS; attempt++ )); do
    if docker pull "${IMAGE}"; then
      return 0
    fi
    if (( attempt < PULL_ATTEMPTS )); then
      backoff=$(( attempt * 5 ))
      echo "blossom image pull attempt ${attempt}/${PULL_ATTEMPTS} failed; retrying in ${backoff}s (transient registry error?)." >&2
      sleep "${backoff}"
    fi
  done
  return 1
}

echo "Pulling blossom image ${IMAGE} (up to ${PULL_ATTEMPTS} attempts)..."
if ! pull_image; then
  echo "ERROR: failed to pull blossom image after ${PULL_ATTEMPTS} attempts; the registry may be unavailable (HTTP 5xx / rate limit)." >&2
  exit 1
fi

echo "Starting blossom: image=${IMAGE} port=${PORT} data=${DATA_DIR}"
docker run -d \
  --name "${CONTAINER}" \
  -p "${PORT}:3000" \
  -v "${DATA_DIR}:/app/data" \
  -v "${CONFIG_FILE}:/app/config.yml:ro" \
  "${IMAGE}" \
  > /dev/null

# Wait for the server to BOTH stay running AND answer HTTP. Unlike strfry, the
# node HTTP server opens its listening socket only after full init, so an HTTP
# response is the authoritative readiness signal. Polling at 1 s intervals;
# total wait bounded by READY_TIMEOUT. `curl` without `-f` because the root
# route may legitimately answer 404 — any HTTP status (i.e. curl exit 0) proves
# the server is up; only a connection failure (exit 7) means "not yet".
deadline=$(( SECONDS + READY_TIMEOUT ))
while (( SECONDS < deadline )); do
  if ! docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null \
       | grep -q true; then
    echo "ERROR: blossom container exited during startup. Logs:" >&2
    docker logs "${CONTAINER}" >&2 || true
    exit 1
  fi
  if curl -s -o /dev/null -m 5 "http://127.0.0.1:${PORT}/"; then
    echo "blossom healthy: container running, port ${PORT} answering HTTP."
    exit 0
  fi
  sleep 1
done

echo "ERROR: blossom never answered HTTP on port ${PORT} within ${READY_TIMEOUT}s. Logs:" >&2
docker logs "${CONTAINER}" >&2 || true
exit 1
