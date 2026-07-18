#!/usr/bin/env bash
# CI guard: the kind-445 exporter label must never be overridden.
#
# Dark Matter's `transport-nostr-peeler` derives the kind-445 outer
# ChaCha20-Poly1305 key (`group_event_key`) via
# MLS-Exporter("marmot", "group-event", 32) — `DEFAULT_EXPORTER_LABEL =
# "marmot/group-event"` (peeler/src/lib.rs:37). Because the engine runs a
# pure-plaintext MLS wire-format policy, that outer wrap is the SOLE MLS-level
# confidentiality layer for group traffic (migration plan §7 Rule 5), so the
# label that keys it is load-bearing for confidentiality, not just interop.
#
# The peeler exposes exactly ONE local lever that can change the derivation:
# the `with_exporter_label` override hook. Calling it — e.g. to stay on the
# legacy pre-migration "nostr" label "for compatibility" — silently forks the
# group_event_key away from every spec-compliant client AND downgrades the
# derivation (plan §4 W3; security finding F14 / §7 Rule 11). Haven must
# never call it, so the identifier must not appear ANYWHERE under
# haven-core/src or haven/rust_builder/src — comments included. Prose that
# needs to mention the hook should reference it descriptively (e.g. "the
# peeler's exporter-label override hook"): a flat token ban needs no
# comment-parsing machinery that a rewording could sidestep.
#
# Pure-grep gate (no Rust toolchain) so it runs fast and independently.
#
# Check:
#   1. The token `with_exporter_label` appears in NO file under haven-core/src
#      or haven/rust_builder/src.
#
# Exit codes:
#   0  all checks pass
#   1  the override hook is referenced somewhere in Haven source
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
FORBIDDEN_TOKEN='with_exporter_label'

log() {
  printf '\033[1;34m[check_no_exporter_label_override]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_exporter_label_override] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "${CORE_SRC_DIR}" ]] || { echo "ERROR: ${CORE_SRC_DIR} not found" >&2; exit 2; }
[[ -d "${FFI_SRC_DIR}" ]] || { echo "ERROR: ${FFI_SRC_DIR} not found" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Check 1: the override hook is named nowhere in Haven's Rust source. Fixed-
# string match (-F), every file type, comments included — see header for why
# the ban is deliberately flat.
# ---------------------------------------------------------------------------
log "Scanning haven-core/src and haven/rust_builder/src for '${FORBIDDEN_TOKEN}' ..."
hits="$(grep -rnF "${FORBIDDEN_TOKEN}" "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" 2>/dev/null || true)"
if [[ -n "${hits}" ]]; then
  printf '%s\n' "${hits}" >&2
  fail "'${FORBIDDEN_TOKEN}' found in Haven source — the peeler's exporter-label override hook is the only local lever that can downgrade the kind-445 exporter derivation away from \"marmot/group-event\" and must never be called (plan §4 W3 / security F14)"
fi

log "OK: no exporter-label override — the kind-445 derivation stays on the spec label."
