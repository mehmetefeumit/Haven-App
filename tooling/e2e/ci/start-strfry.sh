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
#   STRFRY_IMAGE         Docker image. Defaults to an immutable digest
#                        pin of dockurr/strfry:1.1.0 for supply-chain
#                        reproducibility. The CI workflow passes the same
#                        digest (or the STRFRY_IMAGE repo variable when
#                        set); override here for local experimentation.
#   STRFRY_DATA_DIR      Host path mounted at /var/lib/strfry inside
#                        the container (default: /tmp/strfry-data).
#   STRFRY_CONTAINER     Container name (default: strfry).
#   STRFRY_PORT          Host port to publish 7777 on (default: 7777).
#   STRFRY_READY_TIMEOUT Seconds to wait for the relay to come up
#                        (default: 60).
#   STRFRY_PULL_ATTEMPTS Number of `docker pull` attempts (with linear
#                        backoff) before giving up, to ride out a
#                        transient Docker Hub failure (HTTP 5xx /
#                        rate limit) (default: 5).

set -euo pipefail

# Immutable digest pin of dockurr/strfry:1.1.0 (== :latest on
# 2026-06-07), resolved via the Docker Hub registry API. A digest
# pin is preferred over a floating tag so the hermetic relay can't
# silently change between runs. Re-resolve/bump per the runbook.
readonly IMAGE="${STRFRY_IMAGE:-dockurr/strfry@sha256:545555da5dd2c2b502f2c0d159f4dc4996d0e488e3bf25905ce881722d63d2c5}"
readonly DATA_DIR="${STRFRY_DATA_DIR:-/tmp/strfry-data}"
readonly CONTAINER="${STRFRY_CONTAINER:-strfry}"
readonly PORT="${STRFRY_PORT:-7777}"
readonly READY_TIMEOUT="${STRFRY_READY_TIMEOUT:-60}"
readonly PULL_ATTEMPTS="${STRFRY_PULL_ATTEMPTS:-5}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIG_FILE="${script_dir}/../strfry.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: strfry config not found at ${CONFIG_FILE}" >&2
  exit 1
fi

# Failure-only teardown. On a SUCCESSFUL start this script exits 0
# with the container still running in the background for the test
# step to use, so we must NOT tear down on a clean exit. We only
# clean up a half-started container + its data dir when startup
# FAILS, so a broken attempt can't leak a stale container or stale
# events into a later run on a reused self-hosted runner. The
# post-test teardown lives in the workflow's `if: always()` step
# (stop-strfry.sh).
on_exit() {
  local rc=$?
  if (( rc != 0 )); then
    echo "start-strfry.sh failed (rc=${rc}); cleaning up half-started relay." >&2
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    rm -rf "${DATA_DIR}" || true
  fi
  return "${rc}"
}
trap on_exit EXIT

# ---------------------------------------------------------------------------
# image_is_pinned_and_local [<ref>] — 0 (true) when <ref> names a sha256 DIGEST
# and that exact content is already in the local daemon, i.e. when pulling could
# not possibly change what we run. Defaults to ${IMAGE}.
#
# A digest is a content address: `foo@sha256:abc…` present locally IS the bytes
# that digest names, so a re-pull re-verifies something already proven and buys
# nothing but a network dependency. A TAG is deliberately excluded — a local
# `:latest` can be stale, and silently reusing it would be a real change in what
# the lane tests.
#
# This is not an optimisation. A lane may legitimately start a relay at a point
# where outbound HTTPS is already gone: run-b6-location-provider-toggle.sh starts
# its OWN hermetic strfry in Phase 0, and the egress guard that lane installs
# REJECTs TCP 443 for the rest of the job. Without this, that pull failed five
# times and took the lane down while the correct image sat in the local daemon
# the whole time — reported as "Docker Hub may be unavailable" (CI run
# 31075503390).
#
# Takes an argument so `--self-test` can exercise it without a daemon.
image_is_pinned_and_local() {
  local ref="${1:-${IMAGE}}"
  [[ "${ref}" == *"@sha256:"* ]] || return 1
  docker image inspect "${ref}" >/dev/null 2>&1
}

# --self-test — pin the pull-skip decision hermetically, with `docker` stubbed.
#
# One line of shell that can strand a lane in either direction: skip too eagerly
# and a stale tag silently changes what is tested; skip too rarely and a lane
# behind the egress guard dies on a pull it never needed. Neither shows up until
# CI, which is where both have now been paid for.
run_self_test() {
  local fail=0
  _c() { # _c <label> <SKIP|PULL> <ref> <docker-inspect-rc>
    local label="$1" want="$2" ref="$3" rc="$4" got
    docker() { [[ "${1:-}" == "image" ]] && return "${rc}"; return 0; }
    if image_is_pinned_and_local "${ref}"; then got=SKIP; else got=PULL; fi
    unset -f docker
    if [[ "${got}" == "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want %s, got %s)\n' \
        "${label}" "${want}" "${got}" >&2
      fail=1
    fi
  }

  echo "start-strfry.sh --self-test"
  # The case this exists for: pinned AND already local -> no network at all.
  _c "digest-pinned and present locally skips the pull" \
    SKIP 'dockurr/strfry@sha256:abc123' 0
  # Pinned but absent -> must pull, or there is no image to run.
  _c "digest-pinned but absent still pulls" \
    PULL 'dockurr/strfry@sha256:abc123' 1
  # THE SAFETY CASE. A local tag may be stale, and reusing it would silently
  # change what the lane tests — so a tag ALWAYS pulls, present or not.
  _c "a local TAG still pulls (it may be stale)" \
    PULL 'dockurr/strfry:latest' 0
  _c "an absent tag pulls" \
    PULL 'dockurr/strfry:1.1.0' 1

  # THE CALL SITE, not just the predicate. A perfect predicate that nothing
  # consults is the regression restored: disabling the skip at the `if` leaves
  # every fixture above green while the lane dies on a pull behind the guard.
  # Read from the code with comment lines stripped, so a comment that merely
  # MENTIONS the call cannot satisfy it.
  local body
  body="$(grep -v '^[[:space:]]*#' "${BASH_SOURCE[0]}")"
  if ! grep -qE '^if image_is_pinned_and_local; then' <<<"${body}"; then
    printf '  \033[1;31mFAIL\033[0m %s\n' \
      'the pull is no longer guarded by the skip predicate — a lane behind the egress guard will die on a pull it does not need' >&2
    fail=1
  else
    printf '  \033[1;32mPASS\033[0m the pull path actually consults the predicate\n'
  fi

  if (( fail )); then
    echo "start-strfry.sh --self-test: FAILED" >&2
    return 1
  fi
  echo "start-strfry.sh --self-test: all 5 fixtures passed"
  return 0
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit $?
fi

# Idempotent: remove any leftover container from a previous run so
# `docker run --name` doesn't collide. Done BEFORE wiping the data
# dir so a still-running container can't be holding the dir open.
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

# Relay isolation (CI-1): wipe the host data dir before recreating
# it. The deterministic per-actor seeds (Alice [0x01;32], Bob
# [0x02;32], Carol [0x03;32]) are byte-for-byte identical every run,
# so any events left behind by a previous run that didn't tear down
# cleanly (a crashed runner) would be served back as stale state and
# corrupt the next run. Starting from an empty LMDB env guarantees a
# hermetic relay regardless of prior-run hygiene.
rm -rf "${DATA_DIR}"

# The image's default config points at a path the image itself
# doesn't `mkdir`. Pre-create the LMDB env directory on the host
# before the bind-mount so strfry's `mdb_env_open()` succeeds.
mkdir -p "${DATA_DIR}/strfry-db"
chmod -R 777 "${DATA_DIR}"

# Pre-pull the pinned image with a bounded retry + linear backoff.
# `docker run` below would otherwise pull implicitly with NO retry, so a
# single transient Docker Hub failure (e.g. the observed `received
# unexpected HTTP status: 503 Service Temporarily Unavailable`, or a
# registry rate-limit) fails the entire E2E lane. The sha256 digest pin
# is unchanged, so every pull is still content-verified — this only adds
# resilience to a flaky registry (mirrors the repo's cargo-download
# retry hardening). After a successful pull the image is local, so the
# `docker run` does no network I/O.
pull_image() {
  local attempt backoff
  for (( attempt = 1; attempt <= PULL_ATTEMPTS; attempt++ )); do
    if docker pull "${IMAGE}"; then
      return 0
    fi
    if (( attempt < PULL_ATTEMPTS )); then
      backoff=$(( attempt * 5 ))
      echo "strfry image pull attempt ${attempt}/${PULL_ATTEMPTS} failed; retrying in ${backoff}s (transient registry error?)." >&2
      sleep "${backoff}"
    fi
  done
  return 1
}

if image_is_pinned_and_local; then
  echo "strfry image ${IMAGE} is digest-pinned and already local — skipping the pull."
else
  echo "Pulling strfry image ${IMAGE} (up to ${PULL_ATTEMPTS} attempts)..."
  if ! pull_image; then
    echo "ERROR: failed to pull strfry image after ${PULL_ATTEMPTS} attempts." >&2
    # Name the self-inflicted cause FIRST: on these lanes a refusal on :443 is
    # far likelier to be our own egress guard than the registry. `sudo -n` so a
    # developer machine gets a clear error instead of a password prompt.
    if sudo -n iptables -C OUTPUT -j HAVEN_E2E_GUARD 2>/dev/null; then
      echo "  The HAVEN_E2E_GUARD egress guard is INSTALLED and REJECTs" \
           "outbound TCP 443 — that, not Docker Hub, is the likely cause." \
           "setup-network-guard.sh must run AFTER every relay a job starts." >&2
    else
      echo "  Docker Hub may be unavailable (HTTP 5xx / rate limit)." >&2
    fi
    exit 1
  fi
fi

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
