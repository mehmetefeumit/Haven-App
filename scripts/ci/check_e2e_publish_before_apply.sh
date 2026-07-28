#!/usr/bin/env bash
# CI guard: E2E harnesses must resolve every staged circle create.
#
# `CircleManagerFfi.createCircle` STAGES a group creation: MDK puts the group
# into `EpochState::PendingPublish` and only applies it when the application
# reports the outcome via `confirmPublished` (acked) or `publishFailed`
# (rejected) — Security Rule 13, publish-before-apply. The engine contract
# (cgka-traits, `CgkaEngine::ingest`) is explicit about the cost of skipping
# that step:
#
#   "Calls while the group is in `EpochState::PendingPublish` or
#    `EpochState::Merging` return `IngestOutcome::Buffered` and replay once
#    the state returns to `Stable`."
#
# So a harness that stages a create and never resolves it pins that group in
# `PendingPublish` for the life of the process: EVERY inbound kind-445 buffers
# forever, and Haven's live-sync processor deliberately withholds the
# per-circle cursor on `Buffered` (relay/live_sync/processor.rs). The scenario
# then fails on the RECEIVE path — "peer location never surfaced", 20s timeout
# — with nothing pointing back at the create. This exact omission in
# `_m11AliceCreatesCircle` reddened both live-sync E2E lanes from the Dark
# Matter migration onward; before MDK 0.9 the create applied eagerly, so the
# missing confirm was silently harmless.
#
# Production is not at risk (`NostrCircleService.createCircle` confirms), and
# the shared harness helper `createCircleConfirmed`
# (haven/integration_test/e2e/_lib/circle_creation.dart) is the sanctioned way
# for a test to reach the FFI directly. This guard keeps new harnesses on it.
#
# Pure-grep gate (no Flutter toolchain) so it runs fast and independently.
#
# Check:
#   1. Every integration-test file that calls `.createCircle(` also names a
#      resolver — `confirmPublished` or `createCircleConfirmed` — somewhere in
#      the same file. (File-level granularity keeps this a flat grep; the
#      helper file itself is the one allowed definition site.)
#
# Exit codes:
#   0  all checks pass
#   1  an integration test stages a create it never resolves
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IT_DIR="${REPO_ROOT}/haven/integration_test"
HELPER="${IT_DIR}/e2e/_lib/circle_creation.dart"

log() {
  printf '\033[1;34m[check_e2e_publish_before_apply]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_e2e_publish_before_apply] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${IT_DIR}" ]] || { echo "ERROR: ${IT_DIR} not found" >&2; exit 2; }
[[ -f "${HELPER}" ]] || {
  echo "ERROR: ${HELPER} not found — the sanctioned publish-before-apply" \
       "helper is missing; restore it or update this guard" >&2
  exit 2
}

# ---------------------------------------------------------------------------
# Check 1: no integration test stages a create without resolving it.
# ---------------------------------------------------------------------------
log "Scanning ${IT_DIR#"${REPO_ROOT}/"} for unresolved staged circle creates ..."

violations=""
while IFS= read -r file; do
  # The helper itself defines the sanctioned wrapper — skip it.
  [[ "${file}" == "${HELPER}" ]] && continue
  grep -qF '.createCircle(' "${file}" 2>/dev/null || continue
  if ! grep -qE 'confirmPublished|createCircleConfirmed' "${file}" 2>/dev/null; then
    violations+="  ${file#"${REPO_ROOT}/"}"$'\n'
  fi
done < <(find "${IT_DIR}" -type f -name '*.dart' | sort)

if [[ -n "${violations}" ]]; then
  printf '%s' "${violations}" >&2
  fail "the file(s) above call createCircle() but never confirmPublished/publishFailed the staged create — the group stays in MDK PendingPublish and every inbound kind-445 buffers forever (Security Rule 13). Route the create through createCircleConfirmed() in e2e/_lib/circle_creation.dart"
fi

log "OK: every staged circle create in the E2E harnesses is resolved."
