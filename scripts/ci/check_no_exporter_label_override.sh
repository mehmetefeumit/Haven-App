#!/usr/bin/env bash
# CI guard: the kind-445 exporter label must never be overridden.
#
# Dark Matter's `transport-nostr-peeler` derives the kind-445 outer
# ChaCha20-Poly1305 key (`group_event_key`) via
# MLS-Exporter("marmot", "group-event", 32) — `DEFAULT_EXPORTER_LABEL =
# "marmot/group-event"` (peeler/src/lib.rs:37).
#
# What that wrap protects is NOT uniform across the group's traffic, and this
# header said it was until 2026-08-13 ("the SOLE MLS-level confidentiality
# layer for group traffic"). Corrected, per MARMOT_PROTOCOL_KNOWLEDGE.md
# "PURE_PLAINTEXT wire format: the confidentiality caveat":
#
#   * APPLICATION messages (the kind-25442 location rumors) are PrivateMessage
#     ALWAYS. OpenMLS's `create_message` encrypts unconditionally, and the
#     pure-plaintext policy is enforced only against `is_handshake_message()`.
#     A location is therefore double-sealed: AES-128-GCM under the epoch
#     secret tree, inside this outer wrap.
#   * COMMITS and PROPOSALS are PublicMessage, so the roster, each member's
#     Nostr identity pubkey, their 0xF2F1 identity proofs and the circle name
#     rest on this outer wrap ALONE.
#
# So the label that keys it is load-bearing for confidentiality, not just
# interop — decisively so for group-control traffic, which has no second
# layer to fall back on.
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
# That the peeler still spells the hook this way, so a rename cannot leave
# this ban guarding nothing, is held by haven-core/tests/dependency_surface.rs.
#
# Usage:
#   bash scripts/ci/check_no_exporter_label_override.sh
#   bash scripts/ci/check_no_exporter_label_override.sh --self-test
#
# Exit codes:
#   0  all checks pass (or the self-test passed)
#   1  the override hook is referenced somewhere in Haven source (or the
#      self-test failed)
#   2  expected paths missing (misconfiguration)

set -euo pipefail

REPO_ROOT="${REPO_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
CORE_SRC_DIR="${REPO_ROOT}/haven-core/src"
FFI_SRC_DIR="${REPO_ROOT}/haven/rust_builder/src"
FORBIDDEN_TOKEN='with_exporter_label'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=4

log() {
  printf '\033[1;34m[check_no_exporter_label_override]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_no_exporter_label_override] FAIL:\033[0m %s\n' "$*" >&2
  exit 1
}

run_check() {
  [[ -d "${CORE_SRC_DIR}" ]] || { echo "ERROR: ${CORE_SRC_DIR} not found" >&2; exit 2; }
  [[ -d "${FFI_SRC_DIR}" ]] || { echo "ERROR: ${FFI_SRC_DIR} not found" >&2; exit 2; }

  # -------------------------------------------------------------------------
  # Check 1: the override hook is named nowhere in Haven's Rust source. Fixed-
  # string match (-F), every file type, comments included — see header for why
  # the ban is deliberately flat.
  # -------------------------------------------------------------------------
  log "Scanning haven-core/src and haven/rust_builder/src for '${FORBIDDEN_TOKEN}' ..."
  local hits
  hits="$(grep -rnF "${FORBIDDEN_TOKEN}" "${CORE_SRC_DIR}" "${FFI_SRC_DIR}" 2>/dev/null || true)"
  if [[ -n "${hits}" ]]; then
    printf '%s\n' "${hits}" >&2
    fail "'${FORBIDDEN_TOKEN}' found in Haven source — the peeler's exporter-label override hook is the only local lever that can downgrade the kind-445 exporter derivation away from \"marmot/group-event\" and must never be called (plan §4 W3 / security F14)"
  fi

  log "OK: no exporter-label override — the kind-445 derivation stays on the spec label."
}

# ---------------------------------------------------------------------------
# Self-test: whole trees through the real entry point, a plant under each
# scanned root.
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0 t
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _tree() { # <tree>
    mkdir -p "$1/haven-core/src/nostr/mls" "$1/haven/rust_builder/src"
    printf 'fn peeler() -> NostrPeeler { NostrPeeler::new(signer).with_exporter(exporter) }\n' \
      >"$1/haven-core/src/nostr/mls/manager.rs"
    printf '// The peeler'"'"'s exporter-label override hook is never called.\n' >"$1/haven/rust_builder/src/api.rs"
  }
  _case() { # _case <label> <want-rc> <tree>
    local label="$1" want="$2" got=0
    checked=$(( checked + 1 ))
    REPO_ROOT_OVERRIDE="$3" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || got=$?
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  echo "check_no_exporter_label_override.sh --self-test"
  t="${tmp}/ok"; _tree "${t}"
  _case "a tree that describes the hook without naming it passes" 0 "${t}"

  t="${tmp}/core"; _tree "${t}"
  printf 'fn legacy(p: NostrPeeler) -> NostrPeeler { p.with_exporter_label("nostr") }\n' \
    >"${t}/haven-core/src/nostr/mls/legacy.rs"
  _case "'.with_exporter_label(' under haven-core/src fails" 1 "${t}"

  t="${tmp}/ffi"; _tree "${t}"
  printf '// Never call .with_exporter_label( here.\n' >>"${t}/haven/rust_builder/src/api.rs"
  _case "'.with_exporter_label(' under haven/rust_builder/src (in a comment) fails" 1 "${t}"

  t="${tmp}/missing"; _tree "${t}"; rm -r "${t}/haven/rust_builder/src"
  _case "a missing root is a misconfiguration" 2 "${t}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
}

case "${1:-}" in
  --self-test) self_test ;;
  '') run_check ;;
  *) echo "usage: $(basename "$0") [--self-test]" >&2; exit 2 ;;
esac
