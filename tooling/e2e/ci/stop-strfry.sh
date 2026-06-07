#!/usr/bin/env bash
#
# Tears down the hermetic strfry Nostr relay started by
# `start-strfry.sh`: removes the container and wipes its host data
# dir so no events leak into a later E2E run on a reused runner
# (relay isolation, backlog CI-1).
#
# This is the post-test counterpart to start-strfry.sh. The start
# script only cleans up on a FAILED start (leaving a healthy relay
# running for the test); this script is what the workflow's
# `if: always()` teardown step invokes after the test, pass or fail.
#
# Best-effort by design: teardown must never fail the job. A relay
# that's already gone, or a data dir that's already wiped, is the
# success condition, not an error — so every step is guarded and the
# script always exits 0. (`set -u`/`-o pipefail` are still on to
# catch genuine scripting mistakes like an unset variable.)
#
# Why a checked-in script: same rationale as the other tooling/e2e/ci
# scripts — inline multi-line YAML is fragile against shell quirks,
# and keeping the container name / data-dir defaults in one place
# keeps them in sync with start-strfry.sh.
#
# Usage:
#   bash tooling/e2e/ci/stop-strfry.sh
#
# Optional env (must match start-strfry.sh for a clean teardown):
#   STRFRY_DATA_DIR  Host path that was bind-mounted at
#                    /var/lib/strfry (default: /tmp/strfry-data).
#   STRFRY_CONTAINER Container name (default: strfry).

set -uo pipefail

readonly DATA_DIR="${STRFRY_DATA_DIR:-/tmp/strfry-data}"
readonly CONTAINER="${STRFRY_CONTAINER:-strfry}"

echo "Tearing down strfry: container=${CONTAINER} data=${DATA_DIR}"

# Remove the container first so nothing is holding the data dir open
# when we wipe it. `docker rm -f` is idempotent and exits non-zero
# only when the container is already absent — which is fine here, so
# we swallow that single best-effort failure (not a load-bearing
# command: a missing container is the desired end state).
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

# Wipe the LMDB env so the next run starts hermetic. Guarded so a
# permission quirk on a reused runner can't fail the job during
# cleanup.
rm -rf "${DATA_DIR}" || true

echo "strfry teardown complete."
exit 0
