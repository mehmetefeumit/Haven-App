#!/usr/bin/env bash
#
# Tears down the hermetic Blossom media server started by `start-blossom.sh`:
# removes the container and wipes its host data dir so no blobs leak into a
# later E2E run on a reused runner (blob isolation).
#
# This is the post-test counterpart to start-blossom.sh. The start script only
# cleans up on a FAILED start (leaving a healthy server running for the test);
# this script is what the workflow's `if: always()` teardown step invokes after
# the test, pass or fail.
#
# Best-effort by design: teardown must never fail the job. A server that's
# already gone, or a data dir that's already wiped, is the success condition,
# not an error — so every step is guarded and the script always exits 0.
# (`set -u`/`-o pipefail` stay on to catch genuine scripting mistakes.)
#
# Why a checked-in script: same rationale as the other tooling/e2e/ci scripts —
# inline multi-line YAML is fragile against shell quirks, and keeping the
# container name / data-dir defaults in one place keeps them in sync with
# start-blossom.sh.
#
# Usage:
#   bash tooling/e2e/ci/stop-blossom.sh
#
# Optional env (must match start-blossom.sh for a clean teardown):
#   BLOSSOM_DATA_DIR  Host path that was bind-mounted at /app/data
#                     (default: /tmp/blossom-data).
#   BLOSSOM_CONTAINER Container name (default: blossom).

set -uo pipefail

readonly DATA_DIR="${BLOSSOM_DATA_DIR:-/tmp/blossom-data}"
readonly CONTAINER="${BLOSSOM_CONTAINER:-blossom}"

echo "Tearing down blossom: container=${CONTAINER} data=${DATA_DIR}"

# Remove the container first so nothing is holding the data dir open when we
# wipe it. `docker rm -f` is idempotent and exits non-zero only when the
# container is already absent — which is fine here, so we swallow that single
# best-effort failure (a missing container is the desired end state).
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

# Wipe the blob store so the next run starts hermetic. Guarded so a permission
# quirk on a reused runner can't fail the job during cleanup.
rm -rf "${DATA_DIR}" || true

echo "blossom teardown complete."
exit 0
