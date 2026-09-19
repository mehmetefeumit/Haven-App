#!/usr/bin/env bash
# CI guard: a harness must resolve every staged commit, and only on an ack.
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
# ## The second root: the Tier-1 soak rig
#
# `tooling/soak` reaches the same engine from Rust, and the same rule binds it
# harder: it is the world's only publisher, so a `confirm_published` or a
# `finalize_relay_update` with no witnessed ack behind it merges a commit no
# relay ever acknowledged — and every oracle downstream then grades a forked
# world. "Acked" means a relay's `OK` REACHED the publisher
# (`CircleManager::confirm_published`'s own doc), which in the rig is
# `publish_witnessed`/`publish_and_resolve`/`witnessed_ok` and nothing else.
#
# Pure-grep gate (no Flutter or Rust toolchain) so it runs fast and
# independently; file-level granularity keeps it a flat grep.
#
# Checks:
#   1. Every integration-test file that calls `.createCircle(` also names a
#      resolver — `confirmPublished` or `createCircleConfirmed` — somewhere in
#      the same file. (The helper file itself is the one allowed definition
#      site.)
#   2. Every file under tooling/soak that APPLIES a staged commit
#      (`confirm_published`, `finalize_relay_update`) also names a witness
#      (`publish_witnessed`, `publish_and_resolve`, `publish_and_confirm`,
#      `witnessed_ok`) in the same file.
#
# Usage:
#   check_e2e_publish_before_apply.sh              run both checks over the tree
#   check_e2e_publish_before_apply.sh --self-test  fixtures, both directions
#
# Exit codes:
#   0  all checks pass
#   1  a harness stages a create or applies a commit it never proved acked
#   2  expected paths missing (misconfiguration) or the self-test failed

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly REPO_ROOT
readonly IT_REL='haven/integration_test'
readonly HELPER_REL="${IT_REL}/e2e/_lib/circle_creation.dart"
readonly SOAK_REL='tooling/soak'

# How many fixtures the self-test runs. Pinned, because a fixture that stops
# running is the one way a deleted check reports success.
readonly SELF_TEST_FIXTURES=11

log() {
  printf '\033[1;34m[check_e2e_publish_before_apply]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[check_e2e_publish_before_apply] FAIL:\033[0m %s\n' "$*" >&2
  FAILED=1
}

# ---------------------------------------------------------------------------
# Check 1: no integration test stages a create without resolving it.
# ---------------------------------------------------------------------------
check_dart_creates_are_resolved() { # <root>
  local root="$1" it="$1/${IT_REL}" helper="$1/${HELPER_REL}"
  [[ -d "${it}" ]] || return 0
  local violations="" file
  while IFS= read -r file; do
    # The helper itself defines the sanctioned wrapper — skip it.
    [[ "${file}" == "${helper}" ]] && continue
    grep -qF '.createCircle(' "${file}" 2>/dev/null || continue
    if ! grep -qE 'confirmPublished|createCircleConfirmed' "${file}" 2>/dev/null; then
      violations+="  ${file#"${root}/"}"$'\n'
    fi
  done < <(find "${it}" -type f -name '*.dart' | sort)

  if [[ -n "${violations}" ]]; then
    printf '%s' "${violations}" >&2
    fail "the file(s) above call createCircle() but never confirmPublished/publishFailed the staged create — the group stays in MDK PendingPublish and every inbound kind-445 buffers forever (Security Rule 13). Route the create through createCircleConfirmed() in e2e/_lib/circle_creation.dart"
  fi
}

# ---------------------------------------------------------------------------
# Check 2: no soak source or test applies a staged commit without a witness.
# ---------------------------------------------------------------------------
check_soak_commits_are_witnessed() { # <root>
  local root="$1" soak="$1/${SOAK_REL}"
  [[ -d "${soak}" ]] || return 0
  local violations="" file applies witnesses
  local witness='publish_witnessed|publish_and_resolve|publish_and_confirm|witnessed_ok'
  while IFS= read -r file; do
    # Comment lines are dropped on both sides: a file that only MENTIONS the
    # rule in prose has not followed it, and one that mentions `confirm` in
    # prose has not broken it.
    applies="$(grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null \
                 | grep -cE 'confirm_published\(|finalize_relay_update\(' || true)"
    (( applies > 0 )) || continue
    # A DEFINITION is not evidence. `tests/classifier.rs` implements
    # `fn witnessed_ok` for its own relay double and calls none of these, which
    # is exactly the shape a substring match would wave through.
    witnesses="$(grep -vE '^[[:space:]]*//' "${file}" 2>/dev/null \
                   | grep -vE "fn[[:space:]]+(${witness})" \
                   | grep -cE "(${witness})" || true)"
    if (( witnesses == 0 )); then
      violations+="  ${file#"${root}/"}"$'\n'
    fi
  done < <(find "${soak}/src" "${soak}/tests" -type f -name '*.rs' 2>/dev/null | sort)

  if [[ -n "${violations}" ]]; then
    printf '%s' "${violations}" >&2
    fail "the file(s) above confirm or finalize a staged commit with no witnessed publish behind it. In the rig, 'acked' means a relay plane's client-facing stream carried the OK — publish_witnessed()/publish_and_resolve() answer that and nothing else does (Security Rule 13)"
  fi
}

run_all() { # <root>
  check_dart_creates_are_resolved "$1"
  check_soak_commits_are_witnessed "$1"
}

# ---------------------------------------------------------------------------
# Self-test. Every check has a fixture in BOTH directions — the shape that must
# pass and the exact regression that must fail — plus the routes by which each
# could rot into a rubber stamp (a root that is absent, a helper that is
# skipped).
# ---------------------------------------------------------------------------
self_test() {
  local tmp fails=0 checked=0
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  _case() { # _case <label> <want-rc> <fn> <root>
    local label="$1" want="$2" fn="$3" root="$4" got=0
    checked=$(( checked + 1 ))
    ( FAILED=0; "${fn}" "${root}" >/dev/null 2>&1; exit "${FAILED}" ) || got=1
    if [[ "${got}" -eq "${want}" ]]; then
      printf '  \033[1;32mPASS\033[0m %s\n' "${label}"
    else
      printf '  \033[1;31mFAIL\033[0m %s (want rc=%d, got rc=%d)\n' "${label}" "${want}" "${got}" >&2
      fails=1
    fi
  }

  _mk() { # _mk <root> — a tree in the shape both roots expect
    local r="$1"
    mkdir -p "${r}/${IT_REL}/e2e/_lib" "${r}/${SOAK_REL}/src/rig" "${r}/${SOAK_REL}/tests"
    printf 'Future<void> createCircleConfirmed() async { await ffi.createCircle(); await ffi.confirmPublished(p); }\n' \
      > "${r}/${HELPER_REL}"
    printf 'void main() { createCircleConfirmed(); }\n' \
      > "${r}/${IT_REL}/e2e/flow_test.dart"
    printf 'pub async fn go() { publish_witnessed(d, r, e).await; mgr.confirm_published(p).await; }\n' \
      > "${r}/${SOAK_REL}/src/rig/circle.rs"
    printf 'fn control() { let _ = witnessed_ok(&id); mgr.finalize_relay_update(p, g); }\n' \
      > "${r}/${SOAK_REL}/tests/oracles.rs"
  }

  echo "check_e2e_publish_before_apply.sh --self-test"

  # The compliant tree, both roots.
  local ok="${tmp}/ok"; _mk "${ok}"
  _case "a resolved Dart create passes" 0 check_dart_creates_are_resolved "${ok}"
  _case "a witnessed soak commit passes" 0 check_soak_commits_are_witnessed "${ok}"

  # The regressions, one per check.
  local bad_dart="${tmp}/bad-dart"; _mk "${bad_dart}"
  printf 'void main() { ffi.createCircle(); }\n' \
    > "${bad_dart}/${IT_REL}/e2e/flow_test.dart"
  _case "an unresolved Dart create fails" 1 check_dart_creates_are_resolved "${bad_dart}"

  local bad_confirm="${tmp}/bad-confirm"; _mk "${bad_confirm}"
  printf 'fn helper() { mgr.confirm_published(p); }\n' \
    > "${bad_confirm}/${SOAK_REL}/tests/oracles.rs"
  _case "a soak confirm with no witness fails" 1 check_soak_commits_are_witnessed "${bad_confirm}"

  local bad_finalize="${tmp}/bad-finalize"; _mk "${bad_finalize}"
  printf 'fn helper() { mgr.finalize_relay_update(p, g); }\n' \
    > "${bad_finalize}/${SOAK_REL}/src/rig/circle.rs"
  _case "a soak finalize with no witness fails" 1 check_soak_commits_are_witnessed "${bad_finalize}"

  # The rig's own sources are in scope, not only its tests: the world's publish
  # path is where a missing witness would do the most damage.
  local bad_src="${tmp}/bad-src"; _mk "${bad_src}"
  mkdir -p "${bad_src}/${SOAK_REL}/src/scenarios"
  printf 'async fn arm() { mgr.confirm_published(staged.pending).await; }\n' \
    > "${bad_src}/${SOAK_REL}/src/scenarios/s18.rs"
  _case "a soak scenario source with no witness fails" 1 check_soak_commits_are_witnessed "${bad_src}"

  # A file that IMPLEMENTS the witness for its own relay double has not
  # witnessed anything, and a file that only talks about the rule in a comment
  # has not followed it.
  local defines="${tmp}/defines"; _mk "${defines}"
  printf 'impl RelayPlane for PlainRelay { fn witnessed_ok(&self, id: &EventId) -> bool { true } }\nasync fn helper() { mgr.confirm_published(p).await; }\n' \
    > "${defines}/${SOAK_REL}/tests/oracles.rs"
  _case "implementing the witness is not witnessing" 1 check_soak_commits_are_witnessed "${defines}"

  local commented="${tmp}/commented"; _mk "${commented}"
  printf '// publish_witnessed is what Rule 13 wants here.\nfn helper() { mgr.finalize_relay_update(p, g); }\n' \
    > "${commented}/${SOAK_REL}/tests/oracles.rs"
  _case "a comment naming the witness is not a witness" 1 check_soak_commits_are_witnessed "${commented}"

  # The helper is the one allowed definition site; skipping it must not skip
  # anything else.
  local helper_only="${tmp}/helper-only"; _mk "${helper_only}"
  rm -f "${helper_only}/${IT_REL}/e2e/flow_test.dart"
  _case "the sanctioned helper alone passes" 0 check_dart_creates_are_resolved "${helper_only}"

  # An absent root is inert rather than clean-by-accident in the other
  # direction: the full run below is what requires both to exist.
  local no_soak="${tmp}/no-soak"; _mk "${no_soak}"
  rm -rf "${no_soak:?}/${SOAK_REL}"
  _case "an absent soak root is inert" 0 check_soak_commits_are_witnessed "${no_soak}"
  local no_dart="${tmp}/no-dart"; _mk "${no_dart}"
  rm -rf "${no_dart:?}/${IT_REL}"
  _case "an absent integration-test root is inert" 0 check_dart_creates_are_resolved "${no_dart}"

  if (( fails )); then
    echo "self-test: FAILED" >&2
    return 1
  fi
  if (( checked != SELF_TEST_FIXTURES )); then
    echo "self-test: ran ${checked} fixture(s), expected exactly ${SELF_TEST_FIXTURES}. A fixture was added or removed without moving the pin — the one way a deleted fixture reports success." >&2
    return 1
  fi
  echo "self-test: OK (${checked}/${SELF_TEST_FIXTURES} fixtures)"
  return 0
}

main() {
  if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit $?
  fi
  if [[ $# -gt 0 ]]; then
    echo "usage: $(basename "$0") [--self-test]" >&2
    exit 2
  fi

  [[ -d "${REPO_ROOT}/${IT_REL}" ]] || {
    echo "ERROR: ${IT_REL} not found" >&2; exit 2;
  }
  [[ -f "${REPO_ROOT}/${HELPER_REL}" ]] || {
    echo "ERROR: ${HELPER_REL} not found — the sanctioned publish-before-apply" \
         "helper is missing; restore it or update this guard" >&2
    exit 2
  }
  [[ -d "${REPO_ROOT}/${SOAK_REL}/src" ]] || {
    echo "ERROR: ${SOAK_REL}/src not found — the rig is the second root this" \
         "guard owns; restore it or update this guard" >&2
    exit 2
  }

  FAILED=0
  log "Scanning ${IT_REL} and ${SOAK_REL} for unwitnessed staged commits ..."
  run_all "${REPO_ROOT}"
  if (( FAILED )); then
    exit 1
  fi
  log "OK: every staged create and commit in the harnesses is resolved on a witnessed ack."
}

main "$@"
